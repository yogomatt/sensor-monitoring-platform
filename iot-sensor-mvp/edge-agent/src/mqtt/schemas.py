"""T-1.2 payload validation: R-EDGE-1, R-EDGE-7; ADR-002 contracts.

Sequence allocation and monotonicity across messages belong to T-2.2.
"""

from datetime import datetime, timedelta
from typing import Annotated, Union

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator


TopicLevel = Annotated[str, Field(strict=True, min_length=1, pattern=r"^[^/+#\x00]+$")]
NonNegativeInt = Annotated[int, Field(strict=True, ge=0)]
NonEmptyText = Annotated[str, Field(strict=True, min_length=1)]


class _Payload(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    tenant_id: TopicLevel
    device_id: TopicLevel
    timestamp: AwareDatetime
    sequence_no: NonNegativeInt

    @field_validator("timestamp", mode="before")
    @classmethod
    def require_timestamp(cls, value: object) -> object:
        if not isinstance(value, (str, datetime)):
            raise ValueError("timestamp must be an ISO 8601 UTC string or datetime")
        if isinstance(value, str) and "T" not in value:
            raise ValueError("timestamp must contain an ISO 8601 date and time")
        return value

    @field_validator("timestamp")
    @classmethod
    def require_utc(cls, value: datetime) -> datetime:
        if value.utcoffset() != timedelta(0):
            raise ValueError("timestamp must be UTC")
        return value


class ReadingPayload(_Payload):
    """Device reading, including its durable-buffer sequence number."""

    sensor_type: TopicLevel
    value: Annotated[float, Field(strict=True, allow_inf_nan=False)]
    unit: NonEmptyText

    @property
    def topic(self) -> str:
        return f"iot/{self.tenant_id}/{self.device_id}/sensors/{self.sensor_type}"


class HeartbeatPayload(_Payload):
    """ADR-002 heartbeat with sequence_no required by R-EDGE-7."""

    agent_version: NonEmptyText
    buffer_depth: NonNegativeInt
    uptime_seconds: NonNegativeInt

    @property
    def topic(self) -> str:
        return f"iot/{self.tenant_id}/{self.device_id}/status/heartbeat"


def validate_payload(
    topic: str, payload: Union[dict, str, bytes, bytearray]
) -> Union[ReadingPayload, HeartbeatPayload]:
    """Parse a supported MQTT message and match all topic levels to its payload.

    Accept decoded objects or MQTT JSON bytes/text. Invalid payloads raise
    Pydantic ValidationError; unsupported or mismatched topics raise ValueError.
    Topic matching validates consistency, not device authorization (IoT ACLs).
    """
    if not isinstance(topic, str):
        raise ValueError("topic must be a string")
    levels = topic.split("/")
    if len(levels) != 5 or levels[0] != "iot":
        raise ValueError("unsupported MQTT topic")
    if levels[3] == "sensors":
        schema = ReadingPayload
    elif levels[3:] == ["status", "heartbeat"]:
        schema = HeartbeatPayload
    else:
        raise ValueError("unsupported MQTT topic")

    if isinstance(payload, (str, bytes, bytearray)):
        message = schema.model_validate_json(payload)
    else:
        message = schema.model_validate(payload)
    if topic != message.topic:
        raise ValueError("MQTT topic does not match payload identifiers or sensor type")
    return message
