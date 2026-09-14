# Design — IoT Sensor Monitoring Platform: Enterprise Features

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 2: Enterprise) — Design phase |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Derived from** | `requirements.md` Enterprise v1.0 |
| **Depends on** | Increment 1 (MVP) design.md and implementation complete |
| **Status** | Scope locked; builds on MVP architecture |

---

## 1. Architecture additions (Increment 2 scope)

Builds on MVP architecture; adds:
- **Alerting Lambda** triggered by inbound readings and error events
- **S3 raw archive** with Hive-style partitioning (independent write path from IoT Rules Engine)
- **Continuous aggregates** for 1-min and 1-hour rollups
- **FastAPI authorization dependency** enforcing Owner/Admin/Viewer roles
- **slowapi rate limiter** integrated on API endpoints

```
[Sensors] → [Pi 4 Edge Agent] → MQTT/TLS → [AWS IoT Core]
                                                  │
                                       [IoT Rules Engine]
                                     ↙        │         ↘
                          [Lambda Ingestor] [S3 Raw] [Alerting Lambda]
                                     │         │           │
                          [TimescaleDB on RDS] ←─────────────┘
                          ├─ raw (30d)
                          ├─ 1-min rollup (365d)
                          └─ 1-hour rollup (forever)
                                     │
                          [FastAPI on ECS/Fargate]
                            (with RBAC + rate limit)
                                     │
                          [React Dashboard via CloudFront]
```

Satisfies: R-ALERT-1, R-ALERT-2, R-ALERT-3, R-AUTH-2, R-AUTH-5, R-STO-2, R-STO-3, R-STO-4, R-STO-5, R-STO-6, R-STO-7

---

## 2. Component design (Increment 2 additions)

### 2.1 Role-based authorization
**Requirements addressed:** R-AUTH-2

Cognito custom attributes + FastAPI dependency injection:
- Each user has `custom:role` claim: `Owner` | `Admin` | `Viewer`
- FastAPI dependency enforces role on protected endpoints

```python
async def require_role(
    required_roles: List[str],
    token: str = Depends(HTTPBearer())
) -> str:
    """Check user role before allowing access."""
    claims = validate_token(token)
    user_role = claims.get('custom:role')
    if user_role not in required_roles:
        raise HTTPException(status_code=403, detail="Insufficient permissions")
    return user_role

# Usage:
@app.put("/api/v1/alert-rules/{rule_id}")
async def update_alert_rule(
    rule_id: str,
    rule: AlertRuleUpdate,
    tenant_id: str = Depends(get_current_tenant),
    role: str = Depends(lambda: require_role(['Owner', 'Admin']))
):
    # Only Owner/Admin can modify alert rules
    ...
```

**Endpoint matrix:**

| Endpoint | Viewer | Admin | Owner |
|---|---|---|---|
| GET /api/v1/devices | ✓ | ✓ | ✓ |
| GET /api/v1/readings | ✓ | ✓ | ✓ |
| GET /ws/updates | ✓ | ✓ | ✓ |
| POST /api/v1/alert-rules | ✗ | ✓ | ✓ |
| PUT /api/v1/alert-rules/{id} | ✗ | ✓ | ✓ |
| DELETE /api/v1/alert-rules/{id} | ✗ | ✗ | ✓ |

### 2.2 Rate limiting
**Requirements addressed:** R-AUTH-5

slowapi in-memory rate limiter integrated on FastAPI:
- Per-endpoint limits configurable via environment variables
- Example: 100 requests/min per user (identified by JWT sub claim)
- WebSocket connections subject to connection-rate limit, not request-rate limit

```python
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=lambda: get_current_user_id())

@app.get("/api/v1/readings")
@limiter.limit("100/minute")
async def get_readings(...):
    ...
```

**MVP scope:** Single Fargate task; in-memory limit counter. Multi-task scenarios (scale-out) would require Redis-backed limiter (deferred indefinitely per requirements).

### 2.3 Alerting Lambda
**Requirements addressed:** R-ALERT-1, R-ALERT-2, R-ALERT-3

New Lambda function triggered by IoT Rules Engine on two events:
1. **Threshold evaluation** (on each sensor reading)
2. **Error events** (from `status/errors` topic)

Lambda queries `alert_rules` table, evaluates conditions, dispatches via SNS/SES:

```sql
-- alert_rules table schema
CREATE TABLE alert_rules (
    id SERIAL PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    device_id TEXT,  -- NULL means "all devices"
    sensor_type TEXT,
    threshold_min REAL,
    threshold_max REAL,
    operator TEXT CHECK (operator IN ('gt', 'lt', 'gte', 'lte', 'eq')),
    channel_type TEXT CHECK (channel_type IN ('sms', 'email')),
    channel_target TEXT,  -- phone number or email
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE (tenant_id, device_id, sensor_type)
);
```

Lambda logic (pseudocode):
```python
def handler(event, context):
    reading = parse_mqtt_payload(event)
    
    # Query matching rules
    rules = db.query("""
        SELECT * FROM alert_rules
        WHERE tenant_id = %s
          AND (device_id = %s OR device_id IS NULL)
          AND sensor_type = %s
          AND active = TRUE
    """, reading.tenant_id, reading.device_id, reading.sensor_type)
    
    for rule in rules:
        if matches_threshold(reading.value, rule):
            dispatch(rule.channel_type, rule.channel_target, reading)
```

**Dispatch channels:**
- **SNS (SMS):** Create SNS topic per tenant; Lambda publishes alert message
- **SES (Email):** Send via SES SMTP; rate-limited by SES sending quota

**MVP scope:** No alert rule deduplication (same alert can fire multiple times if threshold crossed multiple cycles). Alerting Lambda independent of ingestor; failure in alerting doesn't block data ingestion.

### 2.4 S3 raw archive with Hive-style partitioning
**Requirements addressed:** R-STO-6, R-STO-7

New IoT Rules Engine action writes every reading to S3 in parallel with ingestor Lambda:

```
S3 path: s3://bucket/raw/{tenant_id}/year=YYYY/month=MM/day=DD/hour=HH/{device_id}_{timestamp}_{sequence_no}.json
Example: s3://bucket/raw/acme-corp/year=2026/month=07/day=26/hour=14/device-001_1690387200000_42.json
```

**Payload format (S3 object):**
```json
{
  "tenant_id": "acme-corp",
  "device_id": "device-001",
  "sensor_type": "temperature",
  "value": 22.5,
  "timestamp": "2026-07-26T14:00:00Z",
  "sequence_no": 42
}
```

**Lifecycle policy:**
- Standard storage: days 0–90
- Glacier Instant Retrieval: days 91–3650 (10 years)
- No expiry (permanent archive)

**Query via Athena:**
```sql
SELECT COUNT(*), AVG(value) FROM s3_raw_readings
WHERE tenant_id = 'acme-corp'
  AND year = 2026 AND month = 7 AND day = 26
  AND device_id = 'device-001';
```

Hive-style partitioning means `MSCK REPAIR TABLE` is not required; Athena auto-discovers partition structure.

**Design decision — independent write path:** S3 raw write happens via Rules Engine action, not through ingestor Lambda. This isolates the two paths: if ingestor Lambda fails, raw data still arrives in S3; if S3 write fails, ingestor can still update TimescaleDB. Increases operational resilience at the cost of slightly higher compute (two Lambda invocations per message, but Rules Engine is per-read cost-neutral).

### 2.5 Continuous aggregates (rollups)
**Requirements addressed:** R-STO-2, R-STO-3, R-STO-4

Two continuous aggregates created on `sensor_readings` hypertable:

**1-minute rollup:**
```sql
CREATE MATERIALIZED VIEW sensor_readings_1min
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 minute', time) AS bucket,
  device_id,
  tenant_id,
  sensor_type,
  AVG(value) AS avg_value,
  MIN(value) AS min_value,
  MAX(value) AS max_value,
  COUNT(*) AS reading_count
FROM sensor_readings
GROUP BY 1, 2, 3, 4;

SELECT add_continuous_aggregate_policy(
  'sensor_readings_1min',
  start_offset => INTERVAL '30 min',
  end_offset => INTERVAL '1 min',
  schedule_interval => INTERVAL '1 min'
);

-- Retention: 365 days
SELECT add_retention_policy('sensor_readings_1min', INTERVAL '365 days');
```

**1-hour rollup:**
```sql
CREATE MATERIALIZED VIEW sensor_readings_1hour
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time) AS bucket,
  device_id,
  tenant_id,
  sensor_type,
  AVG(value) AS avg_value,
  MIN(value) AS min_value,
  MAX(value) AS max_value,
  COUNT(*) AS reading_count
FROM sensor_readings
GROUP BY 1, 2, 3, 4;

SELECT add_continuous_aggregate_policy(
  'sensor_readings_1hour',
  start_offset => INTERVAL '2 hours',
  end_offset => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- Retention: FOREVER (no policy)
```

**Dashboard query routing:**
- Request for last 7 days → query raw `sensor_readings`
- Request for 30–365 days → query `sensor_readings_1min`
- Request for > 365 days → query `sensor_readings_1hour`

This keeps query latency flat as data accumulates.

### 2.6 Compression policy
**Requirements addressed:** R-STO-5

TimescaleDB native compression on raw `sensor_readings`:
```sql
ALTER TABLE sensor_readings SET (
  timescaledb.compress = TRUE,
  timescaledb.compress_segmentby = 'tenant_id, device_id, sensor_type'
);

SELECT add_compression_policy(
  'sensor_readings',
  compress_after => INTERVAL '7 days'
);
```

Chunks older than 7 days are automatically compressed. Compression ratio typically 10:1 on time-series data. After compression, chunks are read-only; new data goes into uncompressed chunks.

### 2.7 FastAPI endpoint additions
**Requirements addressed:** R-AUTH-2, R-STO-4

New endpoints for alert rule CRUD and query routing:

```python
@app.post("/api/v1/alert-rules")
async def create_alert_rule(
    rule: AlertRuleCreate,
    tenant_id: str = Depends(get_current_tenant),
    role: str = Depends(lambda: require_role(['Owner', 'Admin']))
):
    # Insert into alert_rules table
    return db.create_alert_rule(tenant_id, rule)

@app.get("/api/v1/readings")
async def get_readings(
    device_id: str,
    start_time: str,
    end_time: str,
    tenant_id: str = Depends(get_current_tenant)
):
    # Query routing: if span > 7 days, use rollup table
    span_days = (parse_datetime(end_time) - parse_datetime(start_time)).days
    
    if span_days > 7:
        table = 'sensor_readings_1min' if span_days <= 365 else 'sensor_readings_1hour'
    else:
        table = 'sensor_readings'
    
    return db.query_readings(table, tenant_id, device_id, start_time, end_time)
```

---

## 3. Data flow (Increment 2 additions)

```
1. Sensor read → SQLite write (published_at = NULL)                    [MVP]
2. SQLite → MQTT publish attempt (QoS 1)                                [MVP]
3. IoT Core → Rules Engine → fan-out:
     a. → Lambda ingestor → TimescaleDB upsert                         [MVP]
     b. → S3 raw write (Hive-partitioned)                              [NEW: R-STO-6, R-STO-7]
     c. → Alerting Lambda → evaluate alert_rules → SNS/SES dispatch   [NEW: R-ALERT-2]
4. Dashboard → FastAPI (JWT bearer, role-checked, rate-limited) →     [NEW: R-AUTH-2, R-AUTH-5]
     query routing (raw vs. 1-min vs. 1-hour rollup)                   [NEW: R-STO-4]
5. Dashboard WebSocket → live push (role-scoped)                       [MVP with new role filtering]
```

**Failure modes (Increment 2):**
- Alerting Lambda fails: readings still in S3 raw archive and TimescaleDB; alerts are dropped (not retried)
- S3 raw write fails: readings in TimescaleDB but missing from archive; eventual consistency (data reappears if S3 recovers)
- Slowapi limiter full: return 429 Too Many Requests; client backs off

---

## 4. Design decisions specific to Increment 2

**Decision 1: Independent S3 write path**
- Justification: Isolation of concerns. Ingestor Lambda failure cannot cause data loss in S3 archive. Operational independence enables easier troubleshooting.

**Decision 2: Continuous aggregates instead of scheduled batch jobs**
- Justification: TimescaleDB aggregates are auto-maintained; no separate cron jobs or ETL service. Operational simplicity.

**Decision 3: Alerting Lambda on every reading (not scheduled)**
- Justification: Near-real-time alerts (within few hundred ms). Scheduled evaluation adds latency and complexity. Cost is linear with reading volume, acceptable at launch scale.

**Decision 4: slowapi rate limiter (not Redis)**
- Justification: Single Fargate task; in-memory limiter is sufficient. Redis would add $10–20/month and operational complexity. Deferred to scale-out phase (if ever reached).

---

## 5. Next steps

- [ ] Review and accept design
- [ ] Proceed to tasks.md for wave-based implementation plan
- [ ] Increment 1 (MVP) must be complete and stable before starting Increment 2 tasks

</content>
