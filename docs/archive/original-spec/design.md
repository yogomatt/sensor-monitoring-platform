# Design — IoT Sensor Monitoring Platform

| Field | Value |
|---|---|
| **Spec type** | Feature Spec — Design phase |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Derived from** | `requirements.md` v1.0 |
| **Status** | Architecture already Accepted via ADR-001–007; this document re-expresses it in spec-driven design.md form |

---

## 1. Architecture overview

```
[Sensors] → [Pi 4 Edge Agent] → MQTT/TLS → [AWS IoT Core]
                                                  │
                                       [IoT Rules Engine]
                                     ↙        │         ↘
                          [Lambda Ingestor] [S3 Raw] [Alerting Lambda]
                                     │                        │
                          [TimescaleDB on RDS] ←──────────────┘
                                     │
                          [FastAPI on ECS/Fargate] ←→ [AWS Cognito]
                                     │
                          [React Dashboard via CloudFront]
```

Satisfies: R-EDGE-*, R-ING-*, R-STO-*, R-TEN-*, R-AUTH-*, R-ALERT-*, R-FE-*

---

## 2. Component design

### 2.1 Edge Agent
**Requirements addressed:** R-EDGE-1 – R-EDGE-8, R-FLEET-4

- **Language/runtime:** Python, containerized via Docker
- **MQTT client:** paho-mqtt, QoS 1, mutual TLS with per-device X.509 cert
- **Local buffer:** SQLite, WAL journal mode, write-ahead pattern (write row → attempt publish → mark sent on ACK)
- **Topic structure:**
  - `iot/{tenant_id}/{device_id}/sensors/{sensor_type}` — readings
  - `iot/{tenant_id}/{device_id}/status/heartbeat` — liveness + buffer depth
  - `iot/{tenant_id}/{device_id}/status/errors` — sensor failures
- **Sequencing:** per-device monotonic `sequence_no`, included in every payload; resets on reimage by design (handled downstream, not here)
- **Buffer limits:** 100,000 row cap, oldest-first eviction, 7-day post-publish retention window

```sql
-- Local buffer schema (subset)
CREATE TABLE sensor_readings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tenant_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    sensor_type TEXT NOT NULL,
    value REAL NOT NULL,
    timestamp TEXT NOT NULL,
    sequence_no INTEGER NOT NULL,
    published_at TEXT DEFAULT NULL
);
```

**Design decision — write-ahead over publish-first:** A crash between sensor read and MQTT publish must not lose the reading. Writing to SQLite first, publishing second, and marking sent only on ACK closes this gap. *(Satisfies R-EDGE-1, R-EDGE-2)*

### 2.2 Fleet Manager (OTA)
**Requirements addressed:** R-FLEET-1 – R-FLEET-3

- AWS IoT Greengrass pulls versioned container images from ECR
- Staged rollout: 10% → 50% → 100% of fleet
- Trigger: `workflow_dispatch` only — **no automatic deploy on merge**, by design, to prevent unintended fleet-wide pushes

### 2.3 Ingestion pipeline
**Requirements addressed:** R-ING-1 – R-ING-5

- AWS IoT Core terminates MQTT/TLS, enforces per-topic ACLs
- IoT Rules Engine fans out one inbound message to three independent actions — no intermediate buffering service (Kinesis evaluated and rejected; native multi-action routing covers the same fan-out need at lower cost and complexity)
- **Dedup strategy:** idempotent upsert at the database layer, not an external dedup store

```sql
ALTER TABLE sensor_readings
  ADD CONSTRAINT uq_device_seq UNIQUE (device_id, sequence_no, time);

INSERT INTO sensor_readings (...)
VALUES (...)
ON CONFLICT (device_id, sequence_no, time) DO NOTHING;
```

**Design decision — why `time` is part of the unique key:** `sequence_no` alone is insufficient because it resets on device reimage. Including the reading's own timestamp in the constraint means a reimaged device's restarted counter cannot collide with historical rows carrying the same low sequence number but an old timestamp. *(Satisfies R-EDGE-8, R-ING-2)*

- **Failure isolation:** S3 raw write happens directly from the Rules Engine action, not via the ingestor Lambda — an ingestor bug or outage cannot cause raw data loss. *(Satisfies R-ING-3, R-ING-4)*

### 2.4 Time-series storage
**Requirements addressed:** R-STO-1 – R-STO-7, R-TEN-1

- TimescaleDB on RDS PostgreSQL, `db.t4g.micro`, Single-AZ
- 4 tables: `sensor_readings` (hypertable), `devices`, `device_heartbeats` (hypertable), `device_errors` (hypertable), plus `alert_rules` (relational) — one instance, no second data store
- Continuous aggregates: 1-minute and 1-hour rollups, auto-refreshed on a schedule
- Retention: raw 30d / 1-min rollup 365d / 1-hour forever / heartbeats 30d / errors 90d
- Compression: `compress_segmentby (tenant_id, device_id, sensor_type)`, policy kicks in at 7 days

**Design decision — dashboard queries hit rollups, not raw table:** Any chart request spanning more than a narrow recent window is served from `sensor_readings_1min` or `sensor_readings_1hour`. This keeps p95 query latency low without requiring a bigger instance at launch scale. *(Satisfies R-STO-4)*

### 2.5 Raw archive
**Requirements addressed:** R-STO-6, R-STO-7

- S3, tenant-first Hive-style partitioning: `raw/{tenant_id}/year=/month=/day=/hour=/{device_id}_{timestamp}_{sequence_no}.json`
- Written directly by the Rules Engine S3 action — independent write path from the ingestor
- Lifecycle: Standard for 90 days → Glacier Instant Retrieval, no expiry
- Athena-queryable out of the box (no `MSCK REPAIR TABLE` needed due to partition naming)

### 2.6 API service
**Requirements addressed:** R-TEN-2, R-TEN-3, R-AUTH-1 – R-AUTH-5

- FastAPI on ECS/Fargate behind an ALB, no API Gateway at launch
- **Tenant scoping:** every query includes `WHERE tenant_id = $1`, where `$1` is extracted server-side from the validated JWT — never accepted as a client-supplied parameter
- **Auth:** AWS Cognito (Essentials tier); JWT carries `custom:tenant_id` and `custom:role`
- **Rate limiting:** slowapi, in-memory, per Fargate task
- **WebSocket auth:** JWT passed as a query parameter on the WS handshake (browsers cannot set custom headers during that handshake); query-string logging explicitly disabled on the WS endpoint to mitigate token leakage into logs

```
User login → Cognito → JWT (RS256, access + id token)
                              │
              FastAPI validates against cached Cognito JWKS
                              │
        Extract: user_id, custom:tenant_id, custom:role
                              │
        Dependency injects tenant scope + enforces role
```

**Design decision — application-layer isolation over RLS:** `tenant_id` already flows from JWT claim to every query via FastAPI dependency injection. Adding PostgreSQL RLS would require session-variable plumbing (`SET app.current_tenant`) across both the Lambda and Fargate connection pools — real defense-in-depth value, but disproportionate operational complexity for a single-digit-tenant launch. Flagged as a documented trade-off, not a gap. *(Satisfies R-TEN-2; trade-off explicit in R-NFR-2)*

### 2.7 Alerting
**Requirements addressed:** R-ALERT-1 – R-ALERT-3

- `alert_rules` table in the same RDS instance as time-series data — no DynamoDB, no second store
- Alerting Lambda triggered off the `status/errors` topic and/or scheduled evaluation
- Query pattern:
```sql
SELECT * FROM alert_rules
WHERE tenant_id = $1
  AND (device_id = $2 OR device_id IS NULL)
  AND sensor_type = $3
  AND active = TRUE;
```
- Delivery via SNS (SMS) / SES (email)

### 2.8 Frontend
**Requirements addressed:** R-FE-1 – R-FE-4

- React + Recharts, served from S3, fronted by CloudFront
- CloudFront's role here is **HTTPS + custom domain + SPA path fallback**, not a latency optimization — S3 alone can't provide TLS on a custom domain or React Router fallback
- Live updates via WebSocket connection to the API service (§2.6)

**Design decision — React over Amazon Managed Grafana:** AMG bills per human viewer ($5–9/user/month, +$45/user for white-label). For a SaaS product where end-customer viewer count is unbounded and unpredictable, this cost scales the wrong direction. A custom React app has flat hosting cost regardless of viewer count. *(Satisfies R-FE-1)*

### 2.9 CI/CD
**Requirements addressed:** R-CICD-1 – R-CICD-5

| Pipeline | Trigger | Rollback mechanism |
|---|---|---|
| Edge | Manual (`workflow_dispatch`) | Inherent to Greengrass staged rollout |
| Lambda | Auto on merge to `main` | Alias repoint to previous published version |
| Fargate | Auto on merge to `main` | ECS task definition revision repoint |
| Frontend | Auto on merge to `main` | S3 object version restore + CloudFront invalidation |

- Four independent workflows across three repos (edge / backend / frontend); Lambda and Fargate share a repo but not a workflow, so a bad deploy in one cannot block rollback in the other
- Retain exactly 1 prior version per target — the minimum needed for the native rollback mechanism to function

---

## 3. Data flow (sequence view)

```
1. Sensor read → SQLite write (published_at = NULL)                     [R-EDGE-1]
2. SQLite → MQTT publish attempt (QoS 1)                                  [R-EDGE-1, R-ING-1]
3. IoT Core → Rules Engine → fan-out:
     a. → Lambda ingestor → TimescaleDB upsert (ON CONFLICT DO NOTHING)  [R-ING-2, R-ING-5]
     b. → S3 raw write (direct, independent path)                        [R-ING-3, R-ING-4]
     c. → Alerting Lambda (on status/errors topic)                       [R-ALERT-2]
4. Dashboard → FastAPI (JWT bearer) → tenant-scoped query → TimescaleDB  [R-TEN-2, R-STO-4]
5. Dashboard → WebSocket (JWT query param) → live push on new readings   [R-FE-4]
```

---

## 4. Design decisions not covered by an existing requirement

None. Every design element in this document maps to at least one requirement ID in `requirements.md`. If a future design change doesn't trace to a requirement, add the requirement first — do not let `design.md` drift ahead of `requirements.md`.

---

## 5. Open design questions

- None — all design elements are Accepted (ADR-001–007) with no unresolved ambiguity at this scope.

## 6. Next steps

- [ ] Generate `tasks.md` from this design (see companion file)
- [ ] On any scope change, update `requirements.md` first, then propagate here
