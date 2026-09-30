"""Tier 2: TypeSafe AI Jev Decision Layer."""

import os
import requests
import logging
from typing import Dict, Any

from src.models import JevNoulResponse, JevScoreResponse

logger = logging.getLogger(__name__)


class JevVerifier:
    def __init__(self, config: Dict[str, Any]):
        self.cfg = config["tier2_jev"]
        api_var = self.cfg.get("api_key_env_var", "TYPESAFE_API_KEY")
        self.api_key = os.getenv(api_var)
        self.base_url = self.cfg.get("base_url", "https://api.typesafe.ai/v1")
        self.model = self.cfg.get("model_version", "typesafe:jev-1.13.0")

    def verify_noul(self, prompt: str, context: str) -> JevNoulResponse:
        if not self.api_key:
            logger.error("TypeSafe API Key not set. Defaulting Jev verification to zero.")
            return JevNoulResponse(noul=0.0, reasoning_summary="Missing API key")

        max_bytes = 32000
        truncated_context = context[:max_bytes] if len(context) > max_bytes else context
        headers = {
            "Authorization": "Bearer " + self.api_key,
            "Content-Type": "application/json"
        }
        payload = {
            "model": self.model,
            "primitive": "noul",
            "prompt": prompt,
            "context": truncated_context
        }
        try:
            res = requests.post(self.base_url + "/decisions", json=payload, headers=headers, timeout=5)
            res.raise_for_status()
            data = res.json()
            return JevNoulResponse(
                noul=data.get("noul", 0.0),
                reasoning_summary=data.get("reasoning_summary")
            )
        except Exception as e:
            logger.error("Jev API request failed: " + str(e))
            return JevNoulResponse(noul=0.0, reasoning_summary="API Error: " + str(e))

    def score_severity(self, prompt: str, context: str) -> JevScoreResponse:
        if not self.api_key:
            return JevScoreResponse(score=1.0)
        headers = {
            "Authorization": "Bearer " + self.api_key,
            "Content-Type": "application/json"
        }
        payload = {
            "model": self.model,
            "primitive": "score",
            "prompt": prompt,
            "context": context[:32000]
        }
        try:
            res = requests.post(self.base_url + "/decisions", json=payload, headers=headers, timeout=5)
            res.raise_for_status()
            return JevScoreResponse(score=res.json().get("score", 1.0))
        except Exception as e:
            logger.error("Jev Score API failed: " + str(e))
            return JevScoreResponse(score=1.0)
