# Tasks — IoT Sensor Monitoring Platform

| Field | Value |
|---|---|
| **Spec type** | Feature Spec — Implementation phase |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Derived from** | `design.md` v1.0 |
| **Status** | Not started — all tasks pending |

---

## How to read this document

Each task lists its **Requirement(s)**, **Depends on** (task IDs that must complete first), and **Status**. Tasks with no unmet dependencies can run concurrently within the same wave. Status values: `pending` / `in-progress` / `done` / `blocked`.

---

## Wave 1 — No dependencies (can start immediately, in parallel)

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-1.1 | Define SQLite buffer schema (`sensor_readings`, `heartbeats`) with WAL mode config | R-EDGE-1, R-EDGE-6 | — | pending |
| T-1.2 | Implement MQTT topic constants and payload Pydantic/dataclass schemas (reading, heartbeat, error) | R-EDGE-1, R-EDGE-5, R-EDGE-7 | — | pending |
| T-1.3 | Provision RDS instance (`db.t4g.micro`, Single-AZ) and enable `timescaledb` extension | R-STO-1 | — | pending |
| T-1.4 | Create Cognito User Pool (Essentials tier) with custom attributes `custom:tenant_id`, `custom:role` | R-AUTH-1, R-AUTH-2 | — | pending |
| T-1.5 | Provision S3 buckets: raw archive + frontend static host | R-STO-6, R-FE-2 | — | pending |
| T-1.6 | Provision ECR repository for edge agent images | R-FLEET-1 | — | pending |
| T-1.7 | Scaffold three repos: edge, backend, frontend (no monorepo) | R-CICD-1 | — | pending |
| T-1.8 | Provision device X.509 certificates and IoT Core thing registry | R-FLEET-4 | — | pending |

---

## Wave 2 — Depends on Wave 1

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-2.1 | Implement edge agent polling loop: sensor read → SQLite write → publish attempt → mark-sent-on-ACK | R-EDGE-1, R-EDGE-2, R-EDGE-3 | T-1.1, T-1.2 | pending |
| T-2.2 | Implement SQLite eviction policy (100K row cap, oldest-first drop, 7-day post-publish purge) | R-EDGE-4 | T-1.1 | pending |
| T-2.3 | Implement per-device `sequence_no` counter (persisted, monotonic) | R-EDGE-7, R-EDGE-8 | T-1.1 | pending |
| T-2.4 | Implement heartbeat emission (agent version, buffer depth, uptime) | R-EDGE-6 | T-1.1, T-1.2 | pending |
| T-2.5 | Implement sensor read failure → `status/errors` publish | R-EDGE-5 | T-1.2 | pending |
| T-2.6 | Create `sensor_readings` hypertable + unique constraint `(device_id, sequence_no, time)` | R-ING-2, R-EDGE-8 | T-1.3 | pending |
| T-2.7 | Create `devices`, `device_heartbeats`, `device_errors`, `alert_rules` tables | R-TEN-1, R-ALERT-1 | T-1.3 | pending |
| T-2.8 | Create 1-min and 1-hour continuous aggregates + refresh policies | R-STO-2, R-STO-3, R-STO-4 | T-2.6 | pending |
| T-2.9 | Apply retention policies (30d/365d/forever/30d/90d per table) | R-STO-1, R-STO-2, R-STO-3 | T-2.6, T-2.7 | pending |
| T-2.10 | Apply compression policy (7-day threshold, segment by tenant/device/sensor) | R-STO-5 | T-2.6 | pending |
| T-2.11 | Configure IoT Rules Engine: sensor topic → Lambda ingestor action + S3 action; errors topic → alerting Lambda action | R-ING-3 | T-1.5, T-1.8 | pending |
| T-2.12 | Configure S3 raw archive key template (Hive-style, tenant-first) + lifecycle rule (Standard → Glacier Instant at 90d) | R-STO-6, R-STO-7 | T-1.5 | pending |
| T-2.13 | Dockerize edge agent, push versioned image to ECR | R-FLEET-1 | T-1.6, T-2.1 | pending |

---

## Wave 3 — Depends on Wave 2

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-3.1 | Implement Lambda ingestor: validate → normalize → `INSERT ... ON CONFLICT DO NOTHING` | R-ING-2, R-ING-5 | T-2.6, T-2.11 | pending |
| T-3.2 | Implement alerting Lambda: query `alert_rules`, evaluate thresholds, dispatch via SNS/SES | R-ALERT-2, R-ALERT-3 | T-2.7, T-2.11 | pending |
| T-3.3 | Configure Greengrass component + staged rollout deployment (10/50/100%) targeting `workflow_dispatch` only | R-FLEET-2, R-FLEET-3 | T-2.13 | pending |
| T-3.4 | Implement FastAPI JWT validation dependency against Cognito JWKS (cached) | R-AUTH-1, R-TEN-3 | T-1.4 | pending |
| T-3.5 | Implement FastAPI role-authorization dependency (Owner/Admin/Viewer) | R-AUTH-2 | T-3.4 | pending |
| T-3.6 | Implement app-layer tenant scoping (`WHERE tenant_id = $1`) across all query functions | R-TEN-2 | T-2.7, T-3.4 | pending |
| T-3.7 | Integrate slowapi in-memory rate limiting on FastAPI routes | R-AUTH-5 | T-3.4 | pending |
| T-3.8 | Implement WebSocket endpoint with JWT-via-query-param auth | R-AUTH-3 | T-3.4 | pending |
| T-3.9 | Configure ALB/CloudWatch logging to exclude query strings on WS endpoint | R-AUTH-4 | T-3.8 | pending |
| T-3.10 | Scaffold React app with Cognito-integrated login flow | R-FE-1, R-FE-4 | T-1.4, T-1.7 | pending |
| T-3.11 | Set up CloudFront distribution: ACM cert, custom domain, SPA fallback routing | R-FE-2, R-FE-3 | T-1.5 | pending |
| T-3.12 | Configure S3 bucket policy for CloudFront OAC; block direct public S3 access | R-FE-2 | T-3.11 | pending |
| T-3.13 | Write edge GitHub Actions workflow (build → ECR push → manual Greengrass trigger) | R-FLEET-3, R-CICD-1, R-CICD-3 | T-1.7, T-2.13 | pending |
| T-3.14 | Write Lambda GitHub Actions workflow (auto-deploy on merge, publish version + alias) | R-CICD-1, R-CICD-2, R-CICD-4 | T-1.7, T-3.1, T-3.2 | pending |
| T-3.15 | Write Fargate GitHub Actions workflow (auto-deploy on merge, new task-def revision) | R-CICD-1, R-CICD-2, R-CICD-4 | T-1.7, T-3.4 | pending |
| T-3.16 | Write frontend GitHub Actions workflow (auto-deploy on merge, S3 sync + CF invalidation) | R-CICD-1, R-CICD-2, R-CICD-4 | T-1.7, T-3.10 | pending |

---

## Wave 4 — Depends on Wave 3

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-4.1 | Build dashboard views: live readings (WebSocket), historical charts (rollup-backed) | R-STO-4, R-FE-4 | T-3.6, T-3.8, T-3.10 | pending |
| T-4.2 | Build alert rule CRUD UI (tenant-scoped) | R-ALERT-1 | T-3.6, T-3.10 | pending |
| T-4.3 | Wire per-tenant branding/theming in React app | R-FE-1 | T-3.10 | pending |
| T-4.4 | Configure rollback procedure docs + verify Lambda alias repoint, ECS task-def repoint, S3 version restore each work end-to-end | R-CICD-4, R-CICD-5 | T-3.14, T-3.15, T-3.16 | pending |
| T-4.5 | End-to-end test: kill edge network mid-cycle, verify zero data loss and correct replay order on reconnect | R-EDGE-2, R-EDGE-3, R-ING-2 | T-2.1, T-3.1 | pending |
| T-4.6 | End-to-end test: force ingestor Lambda failure, verify raw S3 archive still receives the reading | R-ING-4 | T-3.1, T-2.12 | pending |
| T-4.7 | End-to-end test: verify tenant A cannot retrieve tenant B's data via any API or WS route | R-TEN-2, R-TEN-3 | T-3.6, T-3.8 | pending |
| T-4.8 | Load-test rate limiter behavior at launch-scale replica count | R-AUTH-5 | T-3.7 | pending |

---

## Explicitly deferred (do not schedule without a new spec)

Per `requirements.md` out-of-scope section:

- Redis-backed rate limiting
- PostgreSQL RLS
- Multi-AZ RDS
- API Gateway
- Kinesis reintroduction
- Internal ops Grafana dashboard
- dev/staging CI/CD tier

---

## Progress summary

| Wave | Total tasks | Done | In progress | Pending |
|---|---|---|---|---|
| 1 | 8 | 0 | 0 | 8 |
| 2 | 13 | 0 | 0 | 13 |
| 3 | 16 | 0 | 0 | 16 |
| 4 | 8 | 0 | 0 | 8 |
| **Total** | **45** | **0** | **0** | **45** |

## Next steps

- [ ] Assign owners per wave
- [ ] Kick off Wave 1 tasks in parallel (no interdependencies)
- [ ] Update task status inline as work proceeds; do not let this file drift from actual repo state
