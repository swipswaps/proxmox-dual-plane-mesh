"""Local Tool: State Compaction, Anonymization, and Pre-computation."""

import re
from datetime import datetime, timezone
from typing import Tuple


class StatePreprocessor:
    @staticmethod
    def clean_ansi_codes(text: str) -> str:
        ansi_regex = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
        return ansi_regex.sub('', text)

    @staticmethod
    def mask_sensitive_tokens(text: str) -> str:
        text = re.sub(r'(Bearer\s+)[A-Za-z0-9\-\._~\+\/]+=*', r'\1[REDACTED_TOKEN]', text)
        text = re.sub(r'(password\s*=\s*)[^\s&]+', r'\1[REDACTED_PWD]', text, flags=re.IGNORECASE)
        return text

    @classmethod
    def prepare_state_for_jev(cls, raw_logs: str, max_chars: int = 24000) -> Tuple[str, dict]:
        cleaned = cls.clean_ansi_codes(raw_logs)
        sanitized = cls.mask_sensitive_tokens(cleaned)
        lines = [line.strip() for line in sanitized.splitlines() if line.strip()]
        line_count = len(lines)

        if len(sanitized) > max_chars:
            truncated_logs = sanitized[-max_chars:]
            header = "[TRUNCATED: Showing last " + str(max_chars) + " chars of " + str(len(sanitized)) + " total]\n"
            compacted_state = header + truncated_logs
        else:
            compacted_state = sanitized

        metrics = {
            "total_lines": line_count,
            "processed_at_utc": datetime.now(timezone.utc).isoformat(),
            "is_truncated": len(sanitized) > max_chars
        }
        return compacted_state, metrics
