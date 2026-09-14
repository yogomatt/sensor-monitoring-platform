# ADR-003 — Ingestion layer: drop Kinesis, MQTT QoS 1, ingestor deduplication

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-06-24 |
| **Deciders** | Yogo (product owner) |
| **Builds on** | ADR-001 — IoT platform architecture overview; ADR-002 — Edge MQTT/SQLite |

---

## Context

The original ingestion design (ADR-001) routed sensor data through AWS IoT Core → Kinesis Data Streams → Lambda ingestor, with Kinesis retained for replay capability and multi-consumer fan-out. At the launch fleet size (~10 devices, 5 sensors × 5-minute polling, ~1,440 readings/day/device), Kinesis costs ~$11/month while delivering buffering, replay, and fan-out that the workload does not yet require.

Three ingestion-layer decisions needed to be made:

1. Whether to retain Kinesis at launch
2. The MQTT QoS level between the edge agent and IoT Core
3. The strategy for deduplicating readings at the Lambda ingestor

---

## Decision 1 — Drop Kinesis Data Streams at launch

### Decision

Remove Kinesis from the launch architecture. Route IoT Core → IoT Rules Engine → Lambda ingestor directly. Archive raw readings via a direct IoT Rules Engine → S3 action.

### Revised ingestion flow

```
Raspberry Pi (paho-mqtt / TLS, QoS 1)
  → AWS IoT Core
    → IoT Rules Engine
      → Lambda ingestor  → TimescaleDB
      → S3 action        → S3 data lake (raw archive)
      → Alerting Lambda  (status/errors topic)
```

### Rationale

- **Cost:** Removes ~$10.84/month. Ingestion subtotal drops from ~$16 to ~$5/month; platform total ~$89/month at 10 devices.
- **Replay is already covered:** The SQLite edge buffer replays unpublished readings, and the S3 data lake is a permanent raw archive that can be reprocessed. Kinesis replay was largely duplicated.
- **Fan-out is already covered:** IoT Rules Engine routes one topic to multiple actions (Lambda + S3 + alerting) natively. Kinesis multi-consumer fan-out is only needed with several independent stream consumers, which do not exist at launch.
- **No bursts to buffer:** At ~1,440 points/day/device there is no burst pressure; Lambda concurrency handles the volume trivially.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| Retain Kinesis (1 shard) | ~$11/month for replay + fan-out the workload does not need; both capabilities already provided by SQLite buffer + S3 + Rules Engine |
| Kinesis Firehose to S3 | Off the table once Kinesis is dropped; direct Rules Engine → S3 action is simpler and cheaper |

### Out of scope

- **Kinesis re-introduction trigger:** Explicitly out of scope for this ADR. No threshold analysis performed.

---

## Decision 2 — MQTT QoS 1 (at-least-once)

### Decision

The edge agent publishes to IoT Core at **QoS 1 (at-least-once)**.

### MQTT QoS levels

| Level | Guarantee | Mechanism | Duplicates? |
|---|---|---|---|
| QoS 0 | At most once | Fire-and-forget, no ACK | No (but may lose messages) |
| QoS 1 | At least once | Resend until PUBACK received | Yes (lost PUBACK → resend) |
| QoS 2 | Exactly once | 4-step handshake (PUBLISH/PUBREC/PUBREL/PUBCOMP) | No |

### Rationale

- **AWS IoT Core does not support QoS 2** — only QoS 0 and 1. QoS 2 is not an available option on this stack.
- **QoS 0 is too weak** for a commercial sensor product — silently dropped readings undermine the offline-resilience guarantee the SQLite buffer exists to provide.
- **QoS 1 guarantees delivery.** Its only downside is duplicates, which must be handled anyway because SQLite edge replay also produces duplicates. The cost of QoS 1's weakness is therefore already paid.

### End-to-end delivery guarantee

```
SQLite write-first buffer  → no loss on crash / outage
+ MQTT QoS 1               → no loss in transit
+ ingestor deduplication   → absorbs duplicates from both
```

---

## Decision 3 — Ingestor deduplication via idempotent upsert (Option A)

### Decision

Deduplicate at the Lambda ingestor using a **TimescaleDB unique constraint with `ON CONFLICT DO NOTHING`**. Dedup key: `(device_id, sequence_no, timestamp)`.

### Why deduplication is required

Duplicates arrive from two independent sources:
1. **QoS 1 resends** — a delivered message whose PUBACK was lost is resent.
2. **SQLite edge replay** — rows whose publish was not acknowledged are replayed on the next cycle.

`sequence_no` is per-device monotonically increasing, so `(device_id, sequence_no)` uniquely identifies a logical reading regardless of transmission count.

### Implementation

```sql
-- Unique constraint on the hypertable (must include partitioning column)
ALTER TABLE sensor_readings
  ADD CONSTRAINT uq_device_seq UNIQUE (device_id, sequence_no, timestamp);

-- Ingestor write
INSERT INTO sensor_readings
  (tenant_id, device_id, sensor_type, value, unit, timestamp, sequence_no)
VALUES (...)
ON CONFLICT (device_id, sequence_no, timestamp) DO NOTHING;
```

### Rationale

- **No external state** — the database is the single source of truth; no second system to keep consistent.
- **Inherently correct** — a duplicate is physically impossible to insert; no race window under concurrent Lambdas.
- **Stateless Lambda** — the ingestor stays simple and horizontally scalable.

### TimescaleDB constraint note

A unique constraint on a hypertable **must include the partitioning column** (`timestamp`). The same logical reading always carries the same device-side `timestamp` across resends, so `(device_id, sequence_no, timestamp)` dedupes correctly.

### `sequence_no` reset safeguard

`sequence_no` resets on device reimaging (per ADR-002), so a reimaged device restarts at a low number that could collide with historical keys. Including `timestamp` in the key prevents this: the reimaged device's `sequence_no = 1` carries a new, later timestamp, so `(device_id, 1, new_timestamp)` does not collide with `(device_id, 1, old_timestamp)`.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| **B — DynamoDB dedup table** (conditional write + TTL) | Adds a second service and per-message cost; two-phase-write risk (key recorded but TimescaleDB write fails → reading marked seen but never stored). Only justified with multiple downstream sinks sharing one dedup decision — not the case with one ingestor |
| **C — In-memory Lambda cache** | Lambda execution contexts are ephemeral and parallel; concurrent invocations have separate memory, so duplicates slip through. Viable only as an optimization in front of A/B, never as the guarantee |

---

## Consequences

### Positive
- ~$11/month saved; simpler topology with one fewer managed service
- Raw archive (S3) decoupled from ingestor logic — ingestor failure cannot lose raw data
- End-to-end no-loss guarantee preserved via SQLite + QoS 1 + dedup
- Stateless, horizontally scalable ingestor with no external dedup dependency

### Negative / trade-offs
- No Kinesis stream replay — reprocessing must come from S3 or edge buffer instead
- No native multi-consumer fan-out — adding a second independent consumer later requires re-evaluating the ingestion topology
- Unique constraint adds minor write-path overhead on the hypertable

### Out of scope for this ADR
- Kinesis re-introduction trigger / threshold analysis
- Lambda ingestor normalisation and validation detail
- IoT Rules Engine SQL statement authoring

---

## References

- ADR-001 — IoT platform architecture overview (2026-06-23)
- ADR-002 — Edge layer: MQTT topic structure and SQLite offline buffer (2026-06-24)
- AWS IoT Core supported MQTT QoS levels (0 and 1 only)
- TimescaleDB hypertable unique constraint requirements
