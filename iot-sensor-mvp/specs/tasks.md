# Tasks — IoT Sensor Monitoring Platform: MVP

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 1: MVP) — Implementation phase |
| **Version** | 1.1 |
| **Date** | 2026-09-23 |
| **Derived from** | `design.md` MVP v1.1 |
| **Status** | In progress — T-1.1 through T-1.4 done; 26 tasks pending |

Storage scope follows [ADR-008](../../docs/adr/ADR-008-native-postgresql-storage.md): native PostgreSQL partitioning, manual purging, no compression or rollups in any increment.

---

## How to read this document

Each task lists its **Requirement(s)**, **Depends on** (task IDs that must complete first), and **Status**. Tasks with no unmet dependencies can run concurrently within the same wave. Status values: `pending` / `in-progress` / `done` / `blocked`.

Wave structure prioritizes parallelism: Wave 1 can start immediately; Wave 2 waits only for Wave 1; Wave 3 waits only for Wave 2.

---

## Wave 1 — Infrastructure provisioning (no dependencies, start immediately in parallel)

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-1.1 | Define SQLite buffer schema (`sensor_readings` table) with WAL mode config in edge agent codebase | R-EDGE-1, R-EDGE-2 | — | done |
| T-1.2 | Implement MQTT payload Pydantic schemas (reading, heartbeat) for topic validation | R-EDGE-1, R-EDGE-7 | — | done |
| T-1.3 | Provision RDS PostgreSQL instance (`db.t4g.micro`, Single-AZ, PostgreSQL 15; native partitioning per ADR-008) | R-STO-1 | — | done |
| T-1.4 | Create Cognito User Pool (Essentials tier) with custom attribute `custom:tenant_id` | R-AUTH-1, R-TEN-3 | — | done |
| T-1.5 | Provision S3 bucket for frontend static assets + enable CloudFront access logging | R-FE-2 | — | pending |
| T-1.6 | Scaffold three Git repos: edge-agent, backend (FastAPI), frontend (React) with basic folder structure | — | — | pending |
| T-1.7 | Provision AWS IoT Core MQTT endpoint, device X.509 certificate store, topic ACL templates | R-EDGE-1, R-ING-1 | — | pending |
| T-1.8 | Create CloudFront distribution (S3 origin, ACM certificate, custom domain, SPA fallback) | R-FE-2 | T-1.5 | pending |

---

## Wave 2 — Edge agent implementation & schema creation

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-2.1 | Implement edge agent polling loop: sensor read → SQLite insert → publish to MQTT → mark sent on ACK | R-EDGE-1, R-EDGE-2, R-EDGE-3 | T-1.1, T-1.2 | pending |
| T-2.2 | Implement per-device `sequence_no` counter (SQLite-persisted, monotonically incrementing) | R-EDGE-7 | T-1.1 | pending |
| T-2.3 | Dockerize edge agent, build versioned image, push to ECR repository | — | T-2.1, T-2.2 | pending |
| T-2.4 | Create native `sensor_readings` range-partitioned schema per ADR-008, dedup constraint, tenant/time indexes, and partition creation procedure for current, future, and replay intervals | R-STO-1, R-ING-2, R-EDGE-7, R-TEN-1, R-TEN-2 | T-1.3 | pending |
| T-2.5 | Create `devices` table in RDS (device_id, tenant_id, device_name, created_at); add indexes on tenant_id | R-TEN-1 | T-1.3 | pending |
| T-2.6 | Document and verify manual partition purge procedure preserving at least 30 days of raw readings; no scheduled deletion (ADR-008) | R-STO-1 | T-2.4 | pending |
| T-2.7 | Configure AWS IoT Rules Engine: route `iot/{tenant_id}/{device_id}/sensors/*` to Lambda ingestor action | R-ING-1 | T-1.7 | pending |

---

## Wave 3 — Backend API and Lambda ingestion

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-3.1 | Implement Lambda ingestor function: parse payload → validate → deduplicate → upsert to `sensor_readings` | R-ING-2, R-ING-5 | T-2.4, T-2.7 | pending |
| T-3.2 | Implement FastAPI JWT validation dependency: fetch Cognito JWKS, validate bearer token, cache JWKS | R-AUTH-1, R-TEN-3 | T-1.4 | pending |
| T-3.3 | Implement FastAPI tenant scoping dependency: extract `custom:tenant_id` from JWT, inject into all queries | R-TEN-2, R-TEN-3 | T-3.2 | pending |
| T-3.4 | Implement REST endpoints: `GET /api/v1/devices`, `GET /api/v1/devices/{device_id}/readings` | R-AUTH-1, R-TEN-2 | T-3.3, T-2.5 | pending |
| T-3.5 | Implement WebSocket endpoint at `/ws/updates` with JWT-via-query-param authentication | R-FE-4, R-AUTH-1 | T-3.2 | pending |
| T-3.6 | Deploy FastAPI app to ECS/Fargate (1 task, 0.5 CPU, 1 GB memory, behind ALB) | R-AUTH-1 | T-3.1, T-3.4, T-3.5 | pending |
| T-3.7 | Configure ALB to exclude query strings from access logs (prevent JWT leakage on `/ws/updates` endpoint) | R-AUTH-1 | T-3.6 | pending |

---

## Wave 4 — Frontend and dashboard

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-4.1 | Scaffold React app with Cognito login integration (redirect flow, sessionStorage for JWT) | R-AUTH-1 | T-1.4, T-1.6 | pending |
| T-4.2 | Implement dashboard page: device list + live reading chart (WebSocket-fed, Recharts) | R-FE-4 | T-4.1, T-3.5 | pending |
| T-4.3 | Configure GitHub Actions workflow to auto-build and sync React app to S3 on merge to main | — | T-1.6 | pending |
| T-4.4 | Build and deploy frontend; verify CloudFront serves React app over HTTPS with custom domain | R-FE-2 | T-1.8, T-4.2, T-4.3 | pending |

---

## Wave 5 — Integration testing and validation

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-5.1 | End-to-end test: edge device offline scenario, verify zero data loss and correct replay on reconnect | R-EDGE-1, R-EDGE-2, R-EDGE-3 | T-2.1, T-3.1 | pending |
| T-5.2 | End-to-end test: verify tenant A cannot retrieve tenant B's data via REST API or WebSocket | R-TEN-2, R-TEN-3 | T-3.4, T-3.5 | pending |
| T-5.3 | Load test: generate 100 readings/sec for 1 hour, verify zero data loss and query latency < 500ms | R-STO-1, R-ING-2 | T-3.1, T-3.4 | pending |
| T-5.4 | Document manual provisioning steps for reproduction (infrastructure, Cognito config, device certs) | — | T-1.1 through T-4.4 | pending |

---

## Explicitly deferred (do not schedule without a new spec)

Items in `design.md` § 4 (MVP-specific design decisions):
- Automatic operational database purging — only if needed under a future approved spec; compression and rollups are removed from the product, not deferred
- S3 raw archive with Hive-style partitioning — Increment 2
- Alert rule evaluation and SNS/SES dispatch — Increment 2
- Role-based access control (Owner/Admin/Viewer) — Increment 2
- Rate limiting — Increment 2
- Fleet OTA updates and staged rollouts — Increment 3
- Multi-AZ RDS failover — deferred indefinitely
- CI/CD automation (beyond basic GitHub Actions) — Increment 3
- Redis-backed rate limiting — deferred indefinitely

---

## Progress summary

| Wave | Total tasks | Done | In progress | Pending | Blocked |
|---|---|---|---|---|---|
| 1 | 8 | 4 | 0 | 4 | 0 |
| 2 | 7 | 0 | 0 | 7 | 0 |
| 3 | 7 | 0 | 0 | 7 | 0 |
| 4 | 4 | 0 | 0 | 4 | 0 |
| 5 | 4 | 0 | 0 | 4 | 0 |
| **Total** | **30** | **4** | **0** | **26** | **0** |

---

## Next steps

- T-1.4 done (completion recorded 2026-10-25): account `129896631584`, profile `sensor-monitoring`, region `us-east-2`; Cognito User Pool `iot-sensor-mvp-users` (`us-east-2_Jon5KZgmo`). Live `describe-user-pool` verification confirmed Essentials tier, active deletion protection, and immutable string `custom:tenant_id` with length 1–2048. Resource tags are `Project=sensor-monitoring-platform`, `Increment=mvp`, and `Task=T-1.4`. No users, app clients, hosted-login configuration, or MFA policy were created. See [infrastructure documentation](../infrastructure/README.md). T-3.2 is now unblocked; T-4.1 has its T-1.4 prerequisite satisfied but remains pending T-1.6.
- T-1.3 done (completion recorded 2026-10-12): account `129896631584`, profile `sensor-monitoring`, region `us-east-2`; instance `iot-sensor-mvp-postgres`, endpoint `iot-sensor-mvp-postgres.cl26wmy4ay8s.us-east-2.rds.amazonaws.com:5432`, database `iot_platform`. Verified AWS status `available`, PostgreSQL 15.19, `db.t4g.micro`, Single-AZ, encrypted 20 GiB gp3, active managed secret, deletion protection, and no pending modifications. Live read-only SQL checks passed over hostname-validated TLS: PostgreSQL 15.19, native partitioning available, only `plpgsql` installed. Parameter group `default.postgres15` enforces `rds.force_ssl=1`. Dedicated security group `sg-00305a39ffce388b9` permits TCP 5432 only from the operator IP; subnet group `iot-sensor-mvp-postgres` uses the verified public subnets. One-day backup retention was accepted after the Free Plan rejected seven days; sensor-row retention is unchanged. See [infrastructure documentation](../infrastructure/README.md). T-2.4 and T-2.5 are now unblocked and remain pending; T-2.6 still awaits T-2.4.
- T-1.2 complete: Pydantic reading and heartbeat contracts plus topic/payload matching implemented in `edge-agent/src/mqtt/schemas.py`. Approved clarification: heartbeats require `sequence_no` for the same deduplication purpose as readings (R-EDGE-7); recorded in design §2.1. Temporary validation probes passed for required fields, JSON round-trips, malformed payloads, topic mismatches, and SQLite reading compatibility. Sequence allocation remains T-2.2; heartbeat emission remains deferred.
- T-2.1 is now unblocked by completion of T-1.1 and T-1.2. T-2.2 was already unblocked by T-1.1; both remain pending.
- [ ] Assign owners to remaining ready Wave 1 tasks
- [ ] Assign owners to Wave 2 tasks as their listed dependencies complete (T-2.1, T-2.2, T-2.4, and T-2.5 are ready)
- [ ] Update task status as work proceeds; do not let this file drift from actual repo state
- [ ] On Wave 1 completion, kick off Waves 2–5 in sequence

</content>
