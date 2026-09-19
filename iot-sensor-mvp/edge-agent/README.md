# Edge agent

The MVP edge agent contains the SQLite buffer schema delivered for T-1.1 and MQTT payload validation delivered for T-1.2. Remaining implementation is tracked in the [MVP task plan](../specs/tasks.md).

- [MVP requirements](../specs/requirements.md): R-EDGE-1 and R-EDGE-2 addressed by T-1.1.
- T-1.2 implements the payload contracts supporting R-EDGE-1 and R-EDGE-7, traced to ADR-002. Persistent sequence allocation is implemented separately in T-2.2.
- [MVP design](../specs/design.md)
- [ADR-002](../../docs/adr/ADR-002-edge-mqtt-sqlite.md)

Keep component documentation in this README. Record task completion in the [MVP task plan](../specs/tasks.md); do not create standalone task or completion reports.

## MQTT payloads (T-1.2)

Install dependencies with `python3 -m pip install -r requirements.txt` from this component directory. Add `src` to `PYTHONPATH` to import `mqtt.schemas`.

`ReadingPayload` validates the ADR-002 reading fields, including `unit` and a nonnegative integer `sequence_no`. Its `topic` property returns `iot/{tenant_id}/{device_id}/sensors/{sensor_type}`. Sensor types remain extensible.

`HeartbeatPayload` requires `tenant_id`, `device_id`, `timestamp`, `sequence_no`, `agent_version`, `buffer_depth`, and `uptime_seconds`. Its topic is `iot/{tenant_id}/{device_id}/status/heartbeat`. The required heartbeat sequence number is the approved T-1.2 clarification of R-EDGE-7, serving the same deduplication purpose as reading sequence numbers. Both message types use the per-device counter; allocating that counter is T-2.2. Heartbeat emission remains outside the MVP scope.

```python
from mqtt.schemas import ReadingPayload, validate_payload

reading = ReadingPayload(
    tenant_id="acme-corp",
    device_id="pi-001",
    sensor_type="temperature",
    value=23.4,
    unit="celsius",
    timestamp="2026-06-23T14:05:00Z",
    sequence_no=10482,
)
topic = reading.topic
payload_json = reading.model_dump_json()
validated = validate_payload(topic, payload_json)
```

Timestamps must have a UTC timezone and serialize as ISO 8601 strings. Topic identifiers must be nonempty single levels without MQTT wildcards or NUL. Validation rejects unknown fields, non-finite readings, and coerced numeric values (including booleans). Buffer metadata must be excluded when constructing payloads from SQLite rows.

`validate_payload(topic, payload)` accepts a decoded dictionary or JSON text/bytes, selects the reading or heartbeat schema, and rejects mismatched tenant, device, or sensor identifiers and unsupported topic shapes. Payload validation raises Pydantic `ValidationError`; topic validation raises `ValueError`. Matching a topic is a consistency check; device authorization remains the responsibility of IoT Core ACLs.
