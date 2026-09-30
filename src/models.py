"""Data structures for incident reporting, local detection, and Jev escalation."""

from enum import Enum
from typing import Optional
from pydantic import BaseModel, Field


class IncidentSeverity(str, Enum):
    INFO = "INFO"
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"
    CRITICAL = "CRITICAL"


class RemediationAction(str, Enum):
    IGNORE = "IGNORE"
    RESTART_SERVICE = "RESTART_SERVICE"
    FLUSH_CACHE = "FLUSH_CACHE"
    BLOCK_IP = "BLOCK_IP"
    MANUAL_INTERVENTION = "MANUAL_INTERVENTION"


class Tier1Result(BaseModel):
    is_anomaly: bool = Field(description="True if an issue or anomaly was detected.")
    severity: IncidentSeverity = Field(description="Assessed severity level.")
    confidence: float = Field(description="Confidence score between 0.0 and 1.0.")
    summary: str = Field(description="Brief description of the issue.")
    recommended_action: RemediationAction = Field(
        description="Suggested automated or manual recovery action."
    )


class JevNoulResponse(BaseModel):
    noul: float = Field(description="Probability score between 0.0 and 1.0.")
    reasoning_summary: Optional[str] = Field(
        default=None, description="Internal verification state log."
    )


class JevScoreResponse(BaseModel):
    score: float = Field(description="Calculated score between 1.0 and 5.0.")


class EscalationDecision(BaseModel):
    escalated_to_jev: bool
    jev_verified: bool
    final_confidence: float
    selected_action: RemediationAction
    recovery_executed: bool
    recovery_message: str
