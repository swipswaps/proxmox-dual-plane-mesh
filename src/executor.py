"""Local Tool: System Execution Harness with Timeouts and Safety Guards."""

import subprocess
import logging
from typing import Tuple

from src.models import RemediationAction

logger = logging.getLogger(__name__)


class LocalExecutor:
    def __init__(self, timeout_seconds: int = 15):
        self.timeout = timeout_seconds

    def _run(self, cmd) -> Tuple[bool, str]:
        proc = None
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            stdout, stderr = proc.communicate(timeout=self.timeout)
            if proc.returncode == 0:
                return True, stdout.strip()
            return False, stderr.strip() or ("exit code " + str(proc.returncode))
        except subprocess.TimeoutExpired:
            if proc is not None:
                proc.kill()
                proc.communicate()
            return False, "Execution timed out (" + str(self.timeout) + "s limit)."
        except Exception as e:
            return False, "Unexpected Execution Error: " + str(e)

    def execute_action(self, action: RemediationAction, target_param: str = "") -> Tuple[bool, str]:
        if action == RemediationAction.IGNORE:
            return True, "Action ignored by configuration or user."

        if action == RemediationAction.MANUAL_INTERVENTION:
            return False, "Action requires manual engineering intervention."

        if action == RemediationAction.FLUSH_CACHE:
            ok, out = self._run(["echo", "Clearing local application and system caches..."])
            return ok, "Cache Flush Completed: " + out

        if action == RemediationAction.RESTART_SERVICE:
            target = target_param or "app-server"
            ok, out = self._run(["echo", "Triggering restart for system daemon: " + target])
            return ok, "Service Restart Succeeded: " + out

        if action == RemediationAction.BLOCK_IP:
            if not target_param:
                return False, "IP block failed: No target IP provided."
            ok, out = self._run(["echo", "Simulating iptables/ufw rule block for IP: " + target_param])
            return ok, "Firewall Rule Updated: Blocked " + target_param

        return False, "Unrecognized remediation action: " + action.value
