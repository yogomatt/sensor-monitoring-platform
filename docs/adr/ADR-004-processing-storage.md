# ADR-004 — Processing & storage layer: RDS instance, schema, alerting store, S3 naming

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-07-18 |
| **Deciders** | Yogo (product owner) |
| **Builds on** | ADR-001 — IoT platform architecture overview; ADR-003 — Ingestion layer |

---

## Context

The processing and storage layer was directionally established in ADR-001 (TimescaleDB on RDS, S3 data lake, Lambda alerting) but left four concrete decisions open:

1. Managed TimescaleDB (Tiger Cloud) vs self-hosted RDS, and which instance size
2. The TimescaleDB schema: tables, hypertable configuration, continuous aggregates, retention, and compression
3. The alerting rule data model and where to store it
4. The S3 raw archive naming and partitioning convention

---

## Decision 1 — Self-hosted TimescaleDB on RDS (`db.t4g.micro`, Single-AZ)

### Decision

Run TimescaleDB on **RDS PostgreSQL `db.t4g.micro`, Single-AZ**. Do not use Tiger Cloud (the managed TimescaleDB service, formerly Timescale Cloud).

### Rationale

**Tiger Cloud vs RDS:**

| Factor | Tiger Cloud | RDS |
|---|---|---|
| Cost at launch | ~$30/month | ~$17/month |
| HA | Included on Performance plan | Requires Multi-AZ (~$34/month extra) |
| AWS VPC integration | Requires VPC peering | Native |
| Ops burden | Zero | Manage parameter groups, upgrades |
| AWS ecosystem coherence | Outside AWS account | Fully native |

AWS ecosystem coherence is a stated design value for this platform. Keeping TimescaleDB inside the VPC eliminates a peering dependency, simplifies IAM and security group rules, and consolidates billing and monitoring in one place. The cost difference (~$13/month) does not outweigh the architectural coherence benefit at this scale.

**Instance sizing:**

At launch the workload is ~14,400 writes/day (~0.17 writes/second) across 10 devices × 5 sensors × 5-minute polling. Dashboard queries hit pre-aggregated continuous aggregate views. This fits comfortably in 1 GB RAM with TimescaleDB's hypertable chunking keeping the active working set small.

`db.t4g.micro` provides 2 vCPU (burstable), 1 GB RAM, and ~85 max connections. With one Lambda ingestor and one FastAPI Fargate task, connection headroom is sufficient at launch.

**Single-AZ:** Multi-AZ doubles the DB cost (~$34/month extra) with no proportional benefit at 10-device prototype scale. Deferred until commercial launch risk profile warrants it.

**RDS Proxy:** Deferred. Revisit if Lambda concurrency grows to the point where connections become a bottleneck.

### Upgrade trigger

Move to `db.t4g.small` at ~50 devices or if dashboard query p95 latency degrades.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| Tiger Cloud (Performance plan) | Outside AWS VPC; requires peering; against ecosystem coherence principle |
| `db.t4g.medium` | Over-specified for launch workload; ~$35/month unnecessary overhead |
| Multi-AZ at launch | Doubles DB cost; not warranted at prototype scale |

---

## Decision 2 — TimescaleDB schema

### Tables

**`sensor_readings`** — primary hypertable, 7-day chunks, compressed after 7 days:

```sql
CREATE TABLE sensor_readings (
    time          TIMESTAMPTZ      NOT NULL,
    tenant_id     TEXT             NOT NULL,
    device_id     TEXT             NOT NULL,
    sensor_type   TEXT             NOT NULL,
    value         DOUBLE PRECISION NOT NULL,
    unit          TEXT             NOT NULL,
    sequence_no   BIGINT           NOT NULL
);

SELECT create_hypertable('sensor_readings', 'time', chunk_time_interval => INTERVAL '7 days');

ALTER TABLE sensor_readings
    ADD CONSTRAINT uq_device_seq UNIQUE (device_id, sequence_no, time);

CREATE INDEX ON sensor_readings (tenant_id, device_id, time DESC);
CREATE INDEX ON sensor_readings (tenant_id, sensor_type, time DESC);
```

**`devices`** — relational device registry:

```sql
CREATE TABLE devices (
    device_id        TEXT        PRIMARY KEY,
    tenant_id        TEXT        NOT NULL,
    display_name     TEXT,
    location         TEXT,
    firmware_version TEXT,
    registered_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    active           BOOLEAN     NOT NULL DEFAULT TRUE
);

CREATE INDEX ON devices (tenant_id);
```

**`device_heartbeats`** — liveness hypertable, 7-day chunks:

```sql
CREATE TABLE device_heartbeats (
    time           TIMESTAMPTZ NOT NULL,
    tenant_id      TEXT        NOT NULL,
    device_id      TEXT        NOT NULL,
    agent_version  TEXT,
    buffer_depth   INTEGER     NOT NULL DEFAULT 0,
    uptime_seconds BIGINT
);

SELECT create_hypertable('device_heartbeats', 'time', chunk_time_interval => INTERVAL '7 days');
CREATE INDEX ON device_heartbeats (tenant_id, device_id, time DESC);
```

**`device_errors`** — error event hypertable, 7-day chunks:

```sql
CREATE TABLE device_errors (
    time        TIMESTAMPTZ NOT NULL,
    tenant_id   TEXT        NOT NULL,
    device_id   TEXT        NOT NULL,
    sensor_type TEXT,
    error_code  TEXT        NOT NULL,
    message     TEXT
);

SELECT create_hypertable('device_errors', 'time', chunk_time_interval => INTERVAL '7 days');
CREATE INDEX ON device_errors (tenant_id, device_id, time DESC);
```

**`alert_rules`** — see Decision 3.

### Continuous aggregates

```sql
-- 1-minute rollup
CREATE MATERIALIZED VIEW sensor_readings_1min
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 minute', time) AS bucket,
    tenant_id, device_id, sensor_type,
    AVG(value)   AS avg_value,
    MIN(value)   AS min_value,
    MAX(value)   AS max_value,
    COUNT(*)     AS sample_count
FROM sensor_readings
GROUP BY bucket, tenant_id, device_id, sensor_type;

SELECT add_continuous_aggregate_policy('sensor_readings_1min',
    start_offset => INTERVAL '2 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute');

-- 1-hour rollup (built on 1-min for efficiency)
CREATE MATERIALIZED VIEW sensor_readings_1hour
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', bucket) AS bucket,
    tenant_id, device_id, sensor_type,
    AVG(avg_value)   AS avg_value,
    MIN(min_value)   AS min_value,
    MAX(max_value)   AS max_value,
    SUM(sample_count) AS sample_count
FROM sensor_readings_1min
GROUP BY 1, tenant_id, device_id, sensor_type;

SELECT add_continuous_aggregate_policy('sensor_readings_1hour',
    start_offset => INTERVAL '2 hours',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');
```

### Retention policies

| Table / view | Retention |
|---|---|
| `sensor_readings` | 30 days |
| `sensor_readings_1min` | 1 year (365 days) |
| `sensor_readings_1hour` | Forever (no policy) |
| `device_heartbeats` | 30 days |
| `device_errors` | 90 days |

```sql
SELECT add_retention_policy('sensor_readings',      INTERVAL '30 days');
SELECT add_retention_policy('sensor_readings_1min', INTERVAL '365 days');
SELECT add_retention_policy('device_heartbeats',    INTERVAL '30 days');
SELECT add_retention_policy('device_errors',        INTERVAL '90 days');
```

### Compression

```sql
ALTER TABLE sensor_readings SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'tenant_id, device_id, sensor_type',
    timescaledb.compress_orderby   = 'time DESC'
);

SELECT add_compression_policy('sensor_readings', INTERVAL '7 days');
```

`compress_segmentby` on `(tenant_id, device_id, sensor_type)` groups related rows in columnar storage for maximum compression and fast time-range scans per device on historical data.

### Design notes

- `time` uses device-side reading timestamp (ISO 8601 UTC from MQTT payload), not ingestion time — per ADR-002
- No surrogate key on `sensor_readings` — the unique constraint `(device_id, sequence_no, time)` is sufficient identity; a surrogate adds unnecessary write overhead
- `unit` stored per-row to future-proof against per-tenant unit preferences
- `tenant_id` present in every table from day one; query-layer isolation enforced in FastAPI via `WHERE tenant_id = $1`

---

## Decision 3 — Alerting rules in TimescaleDB (`alert_rules` table)

### Decision

Store alerting threshold configuration in a **plain relational table in the same RDS instance** — not in DynamoDB or any separate store.

```sql
CREATE TABLE alert_rules (
    id                   UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            TEXT             NOT NULL,
    device_id            TEXT,
    sensor_type          TEXT             NOT NULL,
    condition            TEXT             NOT NULL,
    threshold            DOUBLE PRECISION NOT NULL,
    notification_channel TEXT             NOT NULL,
    notification_target  TEXT             NOT NULL,
    active               BOOLEAN          NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);

CREATE INDEX ON alert_rules (tenant_id, device_id, sensor_type) WHERE active = TRUE;
```

`device_id IS NULL` means the rule applies to all devices for that tenant/sensor_type combination.

Alerting Lambda query pattern:
```sql
SELECT * FROM alert_rules
WHERE tenant_id = $1
  AND (device_id = $2 OR device_id IS NULL)
  AND sensor_type = $3
  AND active = TRUE;
```

### Rationale

- One database, one connection, one IAM role — no second service to manage
- Alert rules naturally join with `devices` for validation — trivial in SQL, awkward across two stores
- Read volume is negligible at launch scale; `db.t4g.micro` is unaffected
- DynamoDB adds per-message cost and a two-phase write risk (key recorded but DB write fails → reading lost)

### Alternatives considered

| Option | Reason rejected |
|---|---|
| DynamoDB | Second service, per-message cost, cross-store join complexity, two-phase write risk |
| In-memory Lambda config | Lost on cold start; no persistence; not viable |

---

## Decision 4 — S3 raw archive naming convention

### Decision

```
raw/{tenant_id}/year={YYYY}/month={MM}/day={DD}/hour={HH}/{device_id}_{timestamp}_{sequence_no}.json
```

Example:
```
raw/acme-corp/year=2026/month=07/day=18/hour=14/pi-001_20260718T140500Z_10482.json
```

IoT Rules Engine S3 action key template (uses MQTT payload fields directly):
```
raw/${tenant_id}/year=${timestamp().year}/month=${timestamp().month}/day=${timestamp().day}/hour=${timestamp().hour}/${device_id}_${timestamp()}_${sequence_no}.json
```

### Rationale

- `tenant_id` at root mirrors the MQTT topic hierarchy and enables per-tenant S3 bucket policies and lifecycle rules
- Hive-style partitions (`year=`, `month=`, `day=`, `hour=`) are auto-discovered by Athena — no `MSCK REPAIR TABLE` required
- Filename includes `device_id`, `timestamp`, and `sequence_no` for unique identification and debuggability without opening the file
- Written directly by the IoT Rules Engine S3 action — no Lambda in the write path; ingestor failure cannot lose raw data (per ADR-003)

### S3 lifecycle

```
raw/ prefix:
  Days 0–90:  S3 Standard
  Days 90+:   S3 Glacier Instant Retrieval (~80% storage cost reduction)
  Expiry:     None (permanent retention)
```

Estimated raw data volume at launch: ~29 MB/day (10 devices × ~14,400 readings × ~200 bytes).

---

## Consequences

### Positive
- Revised DB cost: ~$17/month (`db.t4g.micro` + 20 GB gp3) vs ~$52/month originally assumed — saving ~$35/month
- Revised platform total: ~$67/month at 10 devices
- Single RDS instance covers all operational data — time-series, registry, heartbeats, errors, and alert config
- TimescaleDB compression (target up to 95%) on 7-day-old chunks keeps storage cost low as data grows
- Continuous aggregates eliminate raw table scans for dashboard charting
- S3 archive is Athena-queryable out of the box with no additional configuration
- Raw archive write path is decoupled from ingestor — S3 data survives ingestor failures

### Negative / trade-offs
- `db.t4g.micro` has ~85 max connections — Lambda concurrency must be capped; revisit with RDS Proxy if needed
- Single-AZ means DB downtime during RDS maintenance windows and on instance failure; acceptable at prototype scale
- Self-hosted RDS requires managing minor version upgrades and parameter group tuning vs Tiger Cloud's zero-ops model

### Out of scope for this ADR
- Multi-AZ RDS (deferred)
- RDS Proxy (deferred)
- Row-level security (RLS) vs application-layer tenant isolation — open question for API layer design
- Kinesis re-introduction threshold (explicitly out of scope per ADR-003)

---

## References

- ADR-001 — IoT platform architecture overview (2026-06-23)
- ADR-002 — Edge layer: MQTT topic structure and SQLite offline buffer (2026-06-24)
- ADR-003 — Ingestion layer: drop Kinesis, MQTT QoS 1, ingestor deduplication (2026-06-24)
- Architecture note: Processing & storage layer (2026-07-18)
- TimescaleDB hypertable and continuous aggregate documentation
- AWS RDS PostgreSQL instance pricing (us-east-1, verified July 2026)
