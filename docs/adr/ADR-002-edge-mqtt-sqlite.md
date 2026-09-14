# ADR-002 — Edge layer: MQTT topic structure and SQLite offline buffer

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-06-24 |
| **Deciders** | Yogo (product owner) |
| **Builds on** | ADR-001 — IoT platform architecture overview |

---

## Context

The edge agent running on each Raspberry Pi 4 must:

1. Publish sensor readings (temperature, humidity, proximity) to AWS IoT Core over MQTT
2. Survive connectivity outages without losing readings
3. Support a multi-tenant, multi-device deployment from day one
4. Surface sensor failures and agent health to the cloud for alerting and dashboards

Two key design decisions needed to be made: the **MQTT topic naming convention** and the **local offline buffer strategy**.

---

## Decision 1 — MQTT topic structure

### Chosen structure

```
iot/{tenant_id}/{device_id}/sensors/{sensor_type}
iot/{tenant_id}/{device_id}/status/heartbeat
iot/{tenant_id}/{device_id}/status/errors
```

### Alternatives considered

| Option | Reason rejected |
|---|---|
| `sensors/{device_id}/{sensor_type}` (no tenant) | Not multi-tenant; would require breaking change to add tenancy later |
| `{tenant_id}/{device_id}/{sensor_type}` (flat) | No subtree separation between telemetry and status; harder to write selective IoT Rules Engine filters |
| Single topic with all sensors multiplexed | Loses per-sensor IoT Rules Engine filtering; payload becomes complex |

### Rationale

- Placing `tenant_id` at level 2 allows the IoT Rules Engine to filter all traffic for a tenant with `iot/{tenant_id}/#` without scanning other tenants' data
- Separating `sensors/` from `status/` keeps telemetry and operational data independently subscribable and filterable
- Leaf-level `sensor_type` allows future per-sensor rules (e.g. route proximity readings to a separate processor) without restructuring
- Consistent with multi-tenant design principle established in ADR-001

### Payload contracts

**Sensor reading** (`iot/{tenant_id}/{device_id}/sensors/{sensor_type}`):
```json
{
  "tenant_id": "acme-corp",
  "device_id": "pi-001",
  "sensor_type": "temperature",
  "value": 23.4,
  "unit": "celsius",
  "timestamp": "2026-06-23T14:05:00Z",
  "sequence_no": 10482
}
```

- `timestamp`: device-side reading time in ISO 8601 UTC — used for TimescaleDB partitioning, not ingestion time
- `sequence_no`: per-device monotonically increasing integer — used by the Lambda ingestor for deduplication of replayed messages

**Heartbeat** (`iot/{tenant_id}/{device_id}/status/heartbeat`):
```json
{
  "tenant_id": "acme-corp",
  "device_id": "pi-001",
  "timestamp": "2026-06-23T14:05:00Z",
  "agent_version": "1.4.2",
  "buffer_depth": 0,
  "uptime_seconds": 86400
}
```

- `buffer_depth`: count of unpublished rows in SQLite — surfaced on the dashboard so operators can detect backlog accumulation

**Sensor error** (`iot/{tenant_id}/{device_id}/status/errors`):
```json
{
  "tenant_id": "acme-corp",
  "device_id": "pi-001",
  "sensor_type": "temperature",
  "error_code": "SENSOR_READ_FAILURE",
  "message": "I2C timeout on address 0x48",
  "timestamp": "2026-06-23T14:05:00Z"
}
```

- Published on any sensor read failure so that alerting and dashboards can react without requiring log access

---

## Decision 2 — SQLite offline buffer

### Chosen approach: write-ahead queue with mark-as-sent

Every sensor reading is written to a local SQLite database **before** being published to MQTT. On successful publish (MQTT ACK), the row is marked as sent. Pending rows are replayed in `timestamp` order on the next cycle, whether or not a reconnect event is detected.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| In-memory queue only | Readings lost on agent crash or power cut — unacceptable for commercial product |
| File-based queue (JSON/CSV append) | No atomic updates; harder to query pending rows; no index support |
| Redis on-device | Additional dependency; no advantage over SQLite for single-writer workload |
| Publish-first, no buffer | Readings silently dropped during any outage |

### Rationale

- SQLite is zero-configuration, crash-safe with WAL mode, and well-supported in Python
- Write-first ensures no reading is ever lost due to a crash between sensor read and publish
- Mark-as-sent (rather than delete) gives a 7-day audit window for post-hoc inspection
- Per-device `sequence_no` in the payload enables idempotent ingestor writes — safe to replay the same row multiple times

### Schema

```sql
CREATE TABLE sensor_readings (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    tenant_id     TEXT    NOT NULL,
    device_id     TEXT    NOT NULL,
    sensor_type   TEXT    NOT NULL,
    value         REAL    NOT NULL,
    unit          TEXT    NOT NULL,
    timestamp     TEXT    NOT NULL,
    sequence_no   INTEGER NOT NULL,
    published_at  TEXT    DEFAULT NULL,
    retry_count   INTEGER DEFAULT 0,
    created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX idx_pending ON sensor_readings (published_at, timestamp)
    WHERE published_at IS NULL;

CREATE TABLE heartbeats (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp      TEXT    NOT NULL,
    agent_version  TEXT    NOT NULL,
    buffer_depth   INTEGER NOT NULL,
    uptime_seconds INTEGER NOT NULL,
    published_at   TEXT    DEFAULT NULL
);
```

### Operational parameters

| Parameter | Value | Rationale |
|---|---|---|
| Replay batch size per cycle | 50 rows | Balances throughput vs. MQTT pressure; tunable |
| Max buffer rows | 100,000 | ~347 days of headroom at 5 sensors × 5-min polling |
| Max DB file size | 50 MB | Safe for Pi SD card |
| Eviction policy | Drop oldest unpublished rows | Prioritises recent data; dropped rows logged as errors |
| Post-publish retention | 7 days | Audit window before purge |
| Journal mode | WAL | Crash safety; concurrent reads during writes |

### Replay loop (pseudocode)

```
every 5 minutes:
  for each sensor:
    try:
      reading = sensor.read()
      sqlite.insert(reading, published_at=NULL)
    except:
      mqtt.publish(status/errors, error_payload)

  if mqtt.connected:
    pending = sqlite.select(published_at IS NULL, ORDER BY timestamp ASC, LIMIT 50)
    for row in pending:
      ack = mqtt.publish(sensors/{sensor_type}, row)
      if ack:
        sqlite.update(row.id, published_at=now())
      else:
        sqlite.increment(row.id, retry_count)

  sqlite.delete(published_at < now() - 7 days)
```

---

## Consequences

### Positive
- No sensor readings lost during connectivity outages of any duration (up to buffer cap)
- Ingestor receives readings in correct chronological order during replay
- `status/errors` topic enables alerting and dashboard visibility without log access
- `buffer_depth` in heartbeat gives real-time operational visibility into device backlog
- Topic structure is stable and extensible — new sensor types require no structural change

### Negative / trade-offs
- Lambda ingestor **must** implement deduplication on `(device_id, sequence_no)` — replayed rows will arrive as duplicates; failure to deduplicate results in double-counted readings in TimescaleDB
- `sequence_no` resets on device reimaging — ingestor deduplication window must account for this (e.g. time-bounded deduplication)
- SQLite on SD card introduces write wear over time — WAL mode and batched deletes reduce but do not eliminate this

### Out of scope for this ADR
- MQTT QoS level selection (recommend QoS 1 for at-least-once delivery; to be confirmed)
- Greengrass component manifest and deployment strategy (separate ADR or design doc)
- Lambda ingestor deduplication implementation detail

---

## References

- ADR-001 — IoT platform architecture overview (2026-06-23)
- Architecture note: Edge layer — MQTT topic structure & SQLite buffer (2026-06-24)
- AWS IoT Core Rules Engine topic filter syntax
