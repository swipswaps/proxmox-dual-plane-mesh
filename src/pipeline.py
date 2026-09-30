"""Integrated Pipeline: Tier 1 local, Tier 2 Jev, interactive recovery."""

import logging
from typing import Dict, Any, Tuple
from rich.console import Console
from rich.panel import Panel
from rich.prompt import Prompt

from src.models import Tier1Result, EscalationDecision, RemediationAction, IncidentSeverity
from src.preprocessor import StatePreprocessor
from src.deduplicator import DeduplicationCache
from src.tier1_local import Tier1Detector
from src.tier2_jev import JevVerifier
from src.executor import LocalExecutor

console = Console()
logger = logging.getLogger(__name__)


class IntegratedMonitoringPipeline:
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.dedup = DeduplicationCache(ttl_seconds=config.get("dedup_ttl_seconds", 300))
        self.tier1 = Tier1Detector(config)
        self.jev = JevVerifier(config)
        self.executor = LocalExecutor(timeout_seconds=config.get("execution_timeout_seconds", 15))

    def process_incident(self, raw_log_data: str) -> EscalationDecision:
        compacted_logs, meta = StatePreprocessor.prepare_state_for_jev(raw_log_data)

        if self.dedup.is_duplicate(compacted_logs):
            console.print("[dim yellow]Event suppressed: Duplicate incident detected.[/dim yellow]")
            return EscalationDecision(
                escalated_to_jev=False,
                jev_verified=False,
                final_confidence=1.0,
                selected_action=RemediationAction.IGNORE,
                recovery_executed=False,
                recovery_message="Suppressed duplicate incident."
            )

        console.print("\n[bold cyan]=== Stage 1: Local Analysis ===[/bold cyan]")
        t1_res: Tier1Result = self.tier1.evaluate_log_payload(compacted_logs)

        console.print("Anomaly Detected : [bold]" + str(t1_res.is_anomaly) + "[/bold]")
        console.print("Local Confidence : [bold yellow]" + str(round(t1_res.confidence, 2)) + "[/bold yellow]")
        console.print("Assessed Severity: [bold]" + t1_res.severity.value + "[/bold]")
        console.print("Summary          : " + t1_res.summary)

        conf_threshold = self.config["tier1"]["confidence_threshold"]
        should_escalate = t1_res.is_anomaly and (t1_res.confidence < conf_threshold)

        jev_verified = False
        final_conf = t1_res.confidence

        if should_escalate:
            console.print("\n[bold magenta]=== Stage 2: Escalating to Jev ===[/bold magenta]")
            prompt = "Verify if this state indicates a real fault/security breach: " + t1_res.summary
            try:
                jev_res = self.jev.verify_noul(prompt=prompt, context=compacted_logs)
                console.print("Jev Probability (Noul): [bold cyan]" + str(round(jev_res.noul, 2)) + "[/bold cyan]")
                jev_threshold = self.config["tier2_jev"]["verification_threshold"]
                if jev_res.noul >= jev_threshold:
                    jev_verified = True
                    final_conf = jev_res.noul
                    console.print("[bold red]Jev Confirmed Anomaly![/bold red]")
                else:
                    console.print("[bold green]Jev Rejected Anomaly (False Positive).[/bold green]")
            except Exception as e:
                logger.error("Jev API unreachable. Falling back to local rules: " + str(e))
                jev_verified = t1_res.is_anomaly
        else:
            jev_verified = t1_res.is_anomaly and (t1_res.confidence >= conf_threshold)

        executed, msg = self._handle_recovery(t1_res.recommended_action, jev_verified, t1_res.severity)

        return EscalationDecision(
            escalated_to_jev=should_escalate,
            jev_verified=jev_verified,
            final_confidence=final_conf,
            selected_action=t1_res.recommended_action,
            recovery_executed=executed,
            recovery_message=msg
        )

    def _handle_recovery(self, action: RemediationAction, verified: bool, severity: IncidentSeverity) -> Tuple[bool, str]:
        if not verified or action == RemediationAction.IGNORE:
            return False, "No execution required."

        console.print("\n[bold yellow]=== Stage 3: Local Recovery Execution ===[/bold yellow]")
        auto_enabled = self.config["recovery"]["auto_remediate_low_risk"]
        is_low_risk = severity in [IncidentSeverity.INFO, IncidentSeverity.LOW]

        if auto_enabled and is_low_risk and action != RemediationAction.MANUAL_INTERVENTION:
            console.print("[bold green]Auto-executing recovery: " + action.value + "[/bold green]")
            return self.executor.execute_action(action)

        console.print(Panel(
            "Action Required: [bold]" + action.value + "[/bold]\nSeverity: " + severity.value + " (Auto-execution bypassed)",
            title="User Safety Gate"
        ))
        choice = Prompt.ask("Choose recovery option", choices=["execute", "skip"], default="execute")
        if choice == "execute":
            return self.executor.execute_action(action)
        return False, "User skipped execution."
