"""Tier 1: Fast, zero-cost, local detection using Semgrep and Ollama + Instructor."""

import subprocess
import json
import logging
from typing import Dict, Any, Optional
import instructor
from ollama import Client

from src.models import Tier1Result, IncidentSeverity, RemediationAction

logger = logging.getLogger(__name__)


class Tier1Detector:
    def __init__(self, config: Dict[str, Any]):
        self.config = config["tier1"]
        self.client = instructor.from_ollama(
            Client(host=self.config.get("ollama_host", "http://localhost:11434"))
        )

    def run_semgrep_scan(self, target_path: str) -> Optional[Dict[str, Any]]:
        proc = None
        try:
            cmd = [
                "semgrep",
                "--config", self.config.get("semgrep_config", "auto"),
                "--json",
                target_path
            ]
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            stdout, stderr = proc.communicate(timeout=60)
            if proc.returncode in (0, 1):
                return json.loads(stdout)
        except FileNotFoundError:
            logger.warning("Semgrep CLI not installed. Skipping static analysis phase.")
        except subprocess.TimeoutExpired:
            if proc is not None:
                proc.kill()
                proc.communicate()
            logger.error("Semgrep scan timed out.")
        except Exception as e:
            logger.error("Error running Semgrep: " + str(e))
        return None

    def evaluate_log_payload(self, log_data: str) -> Tier1Result:
        system_prompt = (
            "You are a local security and maintenance monitoring agent. "
            "Analyze the provided log trace and output strict structured JSON."
        )
        try:
            response: Tier1Result = self.client.chat.completions.create(
                model=self.config.get("local_model", "llama3.2"),
                response_model=Tier1Result,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": "Logs:\n" + log_data}
                ],
                temperature=0.0
            )
            return response
        except Exception as e:
            logger.error("Tier 1 local model evaluation failed: " + str(e))
            return Tier1Result(
                is_anomaly=True,
                severity=IncidentSeverity.HIGH,
                confidence=0.0,
                summary="Tier 1 local engine error: " + str(e),
                recommended_action=RemediationAction.MANUAL_INTERVENTION
            )
