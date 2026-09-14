# Design — IoT Sensor Monitoring Platform: MVP

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 1: MVP) — Design phase |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Derived from** | `requirements.md` MVP v1.0 |
| **Status** | Scope locked; architecture ready for implementation |

---

## 1. Architecture overview (MVP scope)

```
[Sensors] → [Pi 4 Edge Agent] → MQTT/TLS → [AWS IoT Core]
                                                  │
                                       [IoT Rules Engine]
                                     ↙        │         ↘
                          [Lambda Ingestor] [S3 Raw] [Future: Alerting]
                                     │
                          [TimescaleDB on RDS]
                                     │
                          [FastAPI on ECS/Fargate]
                                     │
                          [React Dashboard via CloudFront]
```

Satisfies: R-EDGE-1, R-EDGE-2, R-EDGE-3, R-EDGE-7, R-ING-1, R-ING-2, R-ING-5, R-STO-1, R-TEN-1, R-TEN-2, R-TEN-3, R-AUTH-1, R-FE-2, R-FE-4

MVP scope focuses on reliable end-to-end sensor data flow with zero data loss and simple JWT authentication. Alerting, RBAC, and fleet management deferred to later increments.

---

## 2. Component design (MVP)

### 2.1 Edge Agent
**Requirements addressed:** R-EDGE-1, R-EDGE-2, R-EDGE-3, R-EDGE-7, R-TEN-1

- **Language/runtime:** Python, containerized via Docker
- **MQTT client:** paho-mqtt, QoS 1, mutual TLS with per-device X.509 cert
- **Local buffer:** SQLite, WAL journal mode, write-ahead pattern
  - Sensor read → write to `sensor_readings` table → attempt MQTT publish → mark sent on ACK
  - Guarantees zero data loss even if device crashes between read and publish
- **Topic structure:**
  - `iot/{tenant_id}/{device_id}/sensors/{sensor_type}` — readings
  - `iot/{tenant_id}/{device_id}/status/heartbeat` — liveness + buffer depth (optional for MVP)
- **Sequencing:** per-device monotonic `sequence_no`, included in every reading payload; resets on reimage (design detail: handled downstream via unique constraint including timestamp)

**Local buffer schema:**
```sql
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

-- WAL mode to ensure write durability
PRAGMA journal_mode = WAL;
```

**MVP scope:** Simple polling loop (read sensor → write SQLite → publish on connect). No eviction policy yet (infinite buffer assumed for small device count); no heartbeat emission.

### 2.2 MQTT and IoT Core
**Requirements addressed:** R-ING-1, R-TEN-1

- AWS IoT Core endpoint terminates MQTT/TLS with per-device X.509 certs
- Topic ACLs enforce device-to-topic isolation (e.g., device can only publish to `iot/{tenant_id}/<its-own-device_id>/*`)
- QoS 1 ensures at-least-once delivery; duplicates handled downstream

**MVP scope:** No device shadow; no job scheduling (reserved for Increment 3 OTA); only MQTT topic routing.

### 2.3 Ingestion pipeline
**Requirements addressed:** R-ING-2, R-ING-5, R-STO-1, R-TEN-1

- AWS IoT Core Routes inbound messages to a Lambda ingestor via IoT Rules Engine
- Lambda validates payload, normalizes schema, performs idempotent upsert into TimescaleDB
- Dedup strategy: unique constraint on `(device_id, sequence_no, time)` at the database layer
  - `time` is included so that a device reset (sequence_no restarts) cannot collide with old historical data

```sql
ALTER TABLE sensor_readings
  ADD CONSTRAINT uq_device_seq UNIQUE (device_id, sequence_no, time);

INSERT INTO sensor_readings (...)
VALUES (...)
ON CONFLICT (device_id, sequence_no, time) DO NOTHING;
```

**MVP scope:** Single ingestor Lambda; no fan-out to separate alerting or S3 paths yet (S3 raw archive deferred to Increment 2). Ingestor failure = data not in TimescaleDB but *will* be replayed by edge on reconnect.

### 2.4 Time-series storage (MVP)
**Requirements addressed:** R-STO-1, R-TEN-1, R-TEN-2

- TimescaleDB on RDS PostgreSQL, `db.t4g.micro`, Single-AZ
- One table: `sensor_readings` (hypertable with time partitioning)
- One table: `devices` (device registry, scoped by tenant_id)
- Retention policy: raw sensor readings kept for 30 days, auto-purged after
- No continuous aggregates yet (no rollups for MVP; full raw data for small device count)

**Schema (MVP):**
```sql
CREATE TABLE devices (
    device_id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    device_name TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Create hypertable
CREATE TABLE sensor_readings (
    time TIMESTAMP NOT NULL,
    device_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    sensor_type TEXT NOT NULL,
    value REAL NOT NULL,
    sequence_no INTEGER NOT NULL
);

SELECT create_hypertable('sensor_readings', 'time', if_not_exists => TRUE);

-- Unique constraint for dedup
ALTER TABLE sensor_readings ADD CONSTRAINT uq_device_seq 
  UNIQUE (device_id, sequence_no, time);

-- Retention policy
SELECT add_retention_policy('sensor_readings', INTERVAL '30 days');
```

**MVP scope:** No compression, no aggregates, no alert_rules table. Simple schema for raw data only.

### 2.5 API service (MVP)
**Requirements addressed:** R-TEN-2, R-TEN-3, R-AUTH-1

- FastAPI on ECS/Fargate (1 task at launch)
- Behind ALB, no API Gateway at this stage
- **Tenant scoping:** every query includes `WHERE tenant_id = $1`, extracted from JWT claim
- **Auth:** AWS Cognito (Essentials tier)
  - JWT carries `custom:tenant_id` claim
  - FastAPI validates JWT against Cognito JWKS (cached)
  - Dependency injection enforces tenant scope on all queries

**API endpoints (MVP):**
- `GET /api/v1/devices` — list devices for authenticated tenant
- `GET /api/v1/devices/{device_id}/readings` — time-range readings (with pagination)
- `GET /api/v1/status` — health check
- `GET /ws/updates` — WebSocket for live reading stream

**Example dependency:**
```python
async def get_current_tenant(token: str = Depends(HTTPBearer())) -> str:
    """Extract and validate tenant_id from JWT; use in all query functions."""
    claims = validate_token(token)
    return claims['custom:tenant_id']

async def get_readings(
    device_id: str,
    tenant_id: str = Depends(get_current_tenant)
) -> List[Reading]:
    # Query ALWAYS includes tenant_id scoping
    return db.query("""
        SELECT * FROM sensor_readings 
        WHERE device_id = %s AND tenant_id = %s 
        ORDER BY time DESC LIMIT 1000
    """, device_id, tenant_id)
```

**MVP scope:** No role-based access control; all authenticated users see all data for their tenant. No rate limiting.

### 2.6 WebSocket live updates
**Requirements addressed:** R-FE-4

- WebSocket endpoint at `/ws/updates` accepts JWT as query parameter (browsers cannot set custom headers on WS handshake)
- On new readings in TimescaleDB, AsyncIO task publishes to connected WebSocket clients
- Scoped by tenant: client only receives readings from devices in their tenant

**MVP scope:** In-memory client registry (single Fargate task); no Redis pub/sub or multi-task broadcasting (deferred to scale-up).

### 2.7 Frontend
**Requirements addressed:** R-AUTH-1, R-FE-2, R-FE-4

- React + Recharts, served from S3, fronted by CloudFront
- CloudFront provides HTTPS + custom domain + SPA path fallback
- Cognito login flow: redirect to login → receive JWT → store in sessionStorage
- Dashboard connects to `/ws/updates` with JWT query param; displays live readings in real-time chart

**Pages (MVP):**
- Login page (Cognito-hosted UI or custom form)
- Dashboard: live readings chart + device list
- No alert rule management UI (deferred to Increment 2)

**MVP scope:** Minimal branding; single-tenant styling. CloudFront invalidation manual (no CI/CD pipeline yet).

### 2.8 AWS infrastructure (MVP)
**Requirements addressed:** R-STO-1, R-TEN-1

Infrastructure provisioned manually or via CDK (state tracking only; no automated rollback):
- **IoT Core:** MQTT endpoint, X.509 cert registry, topic-based ACLs
- **IoT Rules Engine:** route `iot/{tenant_id}/{device_id}/sensors/*` to Lambda ingestor
- **Lambda:** ingestor function (Python runtime, sync trigger on Rules Engine)
- **RDS:** PostgreSQL 15 with TimescaleDB extension, `db.t4g.micro`, Single-AZ, public subnet for simplicity
- **S3:** one bucket for frontend static assets (raw archive deferred to Increment 2)
- **CloudFront:** distribution pointing to S3, ACM certificate, custom domain
- **Cognito:** User Pool with custom attribute `custom:tenant_id`
- **ECS/Fargate:** cluster + service, 1 task, 0.5 CPU / 1 GB memory, run in public subnet with ALB

---

## 3. Data flow (MVP sequence)

```
1. Sensor read → SQLite write (published_at = NULL)                    [R-EDGE-1]
2. SQLite → MQTT publish attempt (QoS 1)                                [R-EDGE-1, R-ING-1]
3. IoT Core → Rules Engine → Lambda ingestor → TimescaleDB upsert      [R-ING-2, R-ING-5]
4. Dashboard REST → FastAPI (JWT bearer) → tenant-scoped query         [R-TEN-2, R-AUTH-1]
5. Dashboard WebSocket (JWT query param) → FastAPI → live push         [R-FE-4]
```

**Failure modes (MVP):**
- Edge loses network: continues buffering locally; replays on reconnect
- Ingestor Lambda fails: reading stays in S3 raw archive (deferred to Increment 2; for MVP, data already in edge buffer and will retry)
- Fargate crashes: CloudWatch logs retained; no in-flight WebSocket clients auto-reconnect (manual refresh required)
- RDS unavailable: Lambda ingestor backs off; edge keeps retrying via MQTT; eventually succeeds when DB back online

---

## 4. Design decisions specific to MVP

**Decision 1: No continuous aggregates or rollups**
- Justification: 10 devices at ~1 reading/min = ~14,400 rows/day. 30-day retention = ~432K rows in Postgres. Query latency on 1 million rows is negligible for MVP scale. Avoid complexity until needed.

**Decision 2: Ingestor-only ingestion path (no S3 fan-out yet)**
- Justification: Simpler Rules Engine config; no race condition between Lambda and S3 write. S3 raw archive (permanent audit trail) added in Increment 2 after MVP validation.

**Decision 3: Single Fargate task, no multi-AZ RDS**
- Justification: Cost constraint ($54/month at launch). Single task sufficient for ~10 devices. RDS failover adds $10+/month. If Fargate crashes, manual restart acceptable at launch; auto-recovery added in Increment 3 (ECS service resilience + multi-AZ deferred).

**Decision 4: No rate limiting or RBAC in MVP**
- Justification: Single tenant / single-digit users at launch. Rate limiting added in Increment 2; RBAC layers in Increment 2 as well.

**Decision 5: JWT query parameter for WebSocket (vs. header-based bearer token)**
- Justification: Browser WebSocket API does not allow custom headers during handshake. Standard workaround is query parameter. Logs must exclude query strings to avoid token leakage.

---

## 5. Next steps

- [ ] Review and accept design
- [ ] Proceed to tasks.md for wave-based implementation plan
- [ ] Provision infrastructure (T-1.1 through T-1.8 in tasks.md)

</content>
