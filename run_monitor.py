#!/usr/bin/env python3
"""Main entry point for the hybrid monitor pipeline."""

import sys
import yaml
import logging
from rich.console import Console
from rich.panel import Panel

from src.pipeline import IntegratedMonitoringPipeline

console = Console()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.FileHandler("monitor.log"), logging.StreamHandler(sys.stdout)]
)


def load_config(path: str = "config.yaml"):
    with open(path, "r") as f:
        return yaml.safe_load(f)


def main():
    console.print(Panel.fit("[bold green]Security & Maintenance Tiered Monitor[/bold green]"))
    config = load_config()
    pipeline = IntegratedMonitoringPipeline(config)

    sample_log = """
    2026-09-30T15:20:01Z [WARN] app.db: High connection pool utilization (94%).
    2026-09-30T15:20:03Z [ERROR] app.http: Incoming request /api/v1/users?id=1%27%20OR%201=1
    2026-09-30T15:20:04Z [CRITICAL] app.auth: Continuous failed login attempts from IP 192.168.1.105 (count: 45)
    """

    console.print("[dim]Analyzing sample log input...[/dim]")
    decision = pipeline.process_incident(sample_log)

    console.print("\n[bold green]=== Final Summary ===[/bold green]")
    console.print("Escalated to Jev : " + str(decision.escalated_to_jev))
    console.print("Jev Verified     : " + str(decision.jev_verified))
    console.print("Final Confidence : " + str(round(decision.final_confidence, 2)))
    console.print("Executed Action  : " + decision.selected_action.value)
    console.print("Recovery Message : " + decision.recovery_message + "\n")


if __name__ == "__main__":
    main()
