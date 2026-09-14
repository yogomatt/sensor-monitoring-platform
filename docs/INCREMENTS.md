# IoT Sensor Monitoring Platform — Three-Increment Delivery Plan

## Overview

The IoT Sensor Monitoring Platform has been decomposed into three independently scoped delivery increments, each with its own `specs/requirements.md`, `specs/design.md`, and `specs/tasks.md`. This document summarizes the scope, dependencies, and key deliverables for each.

---

## Increment 1: MVP (Minimum Viable Platform)

**Spec directory:** `/iot-sensor-mvp/specs/`

**Scope:**
End-to-end sensor → dashboard pipeline with zero data loss. Focus on core reliability without alerting, fleet staging, or complex authorization.

**Key requirements in scope:**
- R-EDGE-1, R-EDGE-2, R-EDGE-3, R-EDGE-7
- R-ING-1, R-ING-2, R-ING-5
- R-STO-1
- R-TEN-1, R-TEN-2, R-TEN-3
- R-AUTH-1
- R-FE-2, R-FE-4

**Key components:**
1. **Edge Agent** — Python, SQLite buffer (WAL mode), write-ahead pattern, monotonic sequence numbers, MQTT QoS 1 publishing
2. **AWS IoT Core + Rules Engine** — MQTT routing to Lambda ingestor
3. **Lambda Ingestor** — Validates, normalizes, idempotent upsert to TimescaleDB with `(device_id, sequence_no, time)` dedup constraint
4. **TimescaleDB (RDS)** — Single hypertable `sensor_readings`, 30-day retention, single-AZ, `db.t4g.micro`
5. **FastAPI (ECS/Fargate)** — Simple JWT auth via Cognito, tenant-scoped queries, WebSocket live updates
6. **React Dashboard** — CloudFront + S3 frontend, Cognito login, live chart via WebSocket
7. **S3 Frontend Hosting** — CloudFront distribution, ACM certificate, SPA routing

**Task count:** 30 tasks across 5 waves
- Wave 1 (8 tasks): Infrastructure provisioning (can run in parallel)
- Wave 2 (7 tasks): Edge agent + schema
- Wave 3 (7 tasks): Backend API + Lambda
- Wave 4 (4 tasks): Frontend
- Wave 5 (4 tasks): Integration testing

**Cost estimate:** ~$54/month (as specified in R-NFR-1)

**Estimated timeline:** 4–6 weeks

---

## Increment 2: Enterprise Features

**Spec directory:** `/iot-sensor-enterprise/specs/`

**Depends on:** Increment 1 (MVP) complete and stable

**Scope:**
Role-based access control, alerting, storage optimization, permanent data archive, cost reduction through aggregation.

**Key requirements in scope:**
- R-ALERT-1, R-ALERT-2, R-ALERT-3
- R-AUTH-2, R-AUTH-5
- R-STO-2, R-STO-3, R-STO-4, R-STO-5
- R-STO-6, R-STO-7 (S3 raw archive with Hive-style partitioning)

**Key additions:**
1. **Alerting Lambda** — Evaluates threshold rules on each inbound reading, dispatches SNS/SES notifications
2. **`alert_rules` table** — Stores tenant-scoped threshold rules, no external rules engine
3. **Continuous Aggregates** — 1-minute and 1-hour rollups, auto-refresh policies
4. **Compression policy** — Chunks > 7 days old compressed via TimescaleDB native compression
5. **S3 Raw Archive** — Separate write path via Rules Engine action, Hive-style `{tenant_id}/year=/month=/day=/hour=/` partitioning, lifecycle to Glacier Instant
6. **FastAPI RBAC** — Owner/Admin/Viewer roles enforced via Cognito custom claims and FastAPI dependency injection
7. **Rate Limiting** — slowapi in-memory limiter on API endpoints

**Task count:** 31 tasks across 5 waves
- Wave 1 (8 tasks): Schema (alert_rules, aggregates, compression), S3 archive, SNS/SES setup
- Wave 2 (5 tasks): Alerting Lambda, S3 action routing, RBAC dependency
- Wave 3 (5 tasks): Query routing, rate limiter, alert CRUD endpoints
- Wave 4 (5 tasks): Frontend enhancements (role display, alert UI, query routing, rate limit indicator)
- Wave 5 (8 tasks): Integration testing, documentation

**Cost impact:** Minimal; reuses MVP infrastructure. S3 raw archive adds ~$2–3/month for 50 devices.

**Estimated timeline:** 3–4 weeks (assuming MVP stable)

---

## Increment 3: Fleet Safety & DevOps

**Spec directory:** `/iot-sensor-fleet-devops/specs/`

**Depends on:** Increments 1 (MVP) and 2 (Enterprise) complete and stable

**Scope:**
Safe OTA updates via staged rollouts, independent CI/CD pipelines, comprehensive end-to-end testing, documented rollback procedures.

**Key requirements in scope:**
- R-FLEET-1, R-FLEET-2, R-FLEET-3, R-FLEET-4
- R-ING-3, R-ING-4 (failure isolation, tested comprehensively)
- R-CICD-1 through R-CICD-7 (independent pipelines and rollback)
- R-TEST-1 through R-TEST-7 (end-to-end testing)
- R-NFR-2, R-NFR-3, R-NFR-4 (upgrade triggers, AWS-native preference, scaling validation)

**Key additions:**
1. **AWS IoT Greengrass** — Staged component deployment (10% → 50% → 100%), canary monitoring
2. **Infrastructure-as-Code (CDK)** — Eight stacks (networking, database, compute, storage, auth, IoT, Lambda), version-controlled, reproducible
3. **Four Independent GitHub Actions Workflows:**
   - Edge: Manual trigger → ECR push → Greengrass deployment
   - Lambda: Auto on merge → new version + alias update
   - Fargate: Auto on merge → new task definition + service update
   - Frontend: Auto on merge → S3 sync + CloudFront invalidate
4. **Comprehensive Test Suite (pytest):**
   - Network failure and replay validation
   - Tenant isolation (REST, WebSocket, database)
   - Ingestor failure doesn't block S3 archive
   - Device reimage (sequence_no reset) handling
   - Load test (500 readings/sec for 10 min)
   - Alerting performance (10k devices/sec)
   - Rollback procedures end-to-end validation
5. **Rollback Runbooks** — Documented procedures for edge, Lambda, Fargate, and frontend with verification steps
6. **Upgrade Trigger Documentation** — Future scaling conditions for RDS, Fargate, Lambda, S3, etc.

**Task count:** 43 tasks across 6 waves
- Wave 1 (10 tasks): CDK infrastructure, Greengrass setup, test deployment validation
- Wave 2 (6 tasks): Four CI/CD workflows, retention policies, documentation
- Wave 3 (9 tasks): Test harness, seven end-to-end tests, CI integration
- Wave 4 (6 tasks): Fleet OTA (Greengrass dry-run, canary setup, rollback validation)
- Wave 5 (7 tasks): Operational runbooks (edge, Lambda, Fargate, frontend rollback, IaC, scaling triggers, incident response)
- Wave 6 (5 tasks): Final integration, disaster recovery drill, smoke tests, performance validation

**Cost impact:** Minimal; test environment adds ~$50/month. Production infrastructure cost unchanged.

**Estimated timeline:** 4–5 weeks (assuming Increments 1 & 2 stable)

---

## Requirement Traceability Matrix

| Requirement ID | Epic | Increment |
|---|---|---|
| R-EDGE-1 through R-EDGE-3, R-EDGE-7 | Sensor data collection | MVP (1) |
| R-EDGE-8 | Device reimage handling | Fleet DevOps (3) |
| R-EDGE-4, R-EDGE-5, R-EDGE-6 | Buffer management, error handling, heartbeats | Deferred (future) |
| R-FLEET-1 through R-FLEET-4 | Fleet OTA | Fleet DevOps (3) |
| R-ING-1, R-ING-2, R-ING-5 | Dedup ingestion | MVP (1) |
| R-ING-3, R-ING-4 | Failure isolation | Fleet DevOps (3) tested |
| R-STO-1 | 30-day raw retention | MVP (1) |
| R-STO-2 through R-STO-5 | Aggregates, compression, cost optimization | Enterprise (2) |
| R-STO-6, R-STO-7 | S3 raw archive | Enterprise (2) |
| R-TEN-1 through R-TEN-3 | Multi-tenant isolation | MVP (1) |
| R-AUTH-1 | Basic JWT auth | MVP (1) |
| R-AUTH-2 | Role-based access control | Enterprise (2) |
| R-AUTH-3 | WebSocket JWT auth | MVP (1) |
| R-AUTH-4 | Log query string exclusion | Fleet DevOps (3) tested |
| R-AUTH-5 | Rate limiting | Enterprise (2) |
| R-ALERT-1 through R-ALERT-3 | Alerting | Enterprise (2) |
| R-FE-1 through R-FE-4 | Dashboard | MVP (1) & Enterprise (2) |
| R-CICD-1 through R-CICD-5 | Deployment & rollback | Fleet DevOps (3) |
| R-CICD-6, R-CICD-7 | IaC, runbooks | Fleet DevOps (3) |
| R-NFR-1 | Cost target | MVP (1) |
| R-NFR-2 through R-NFR-4 | Scaling, AWS-native, upgrade triggers | Fleet DevOps (3) |

---

## Key Design Principles (all increments)

1. **Write-ahead pattern:** Edge writes to SQLite before attempting MQTT publish → zero data loss
2. **Idempotent dedup:** Database-layer unique constraint on `(device_id, sequence_no, time)` — no external dedup store
3. **Failure isolation:** S3 raw archive independent of ingestor Lambda; alerting Lambda independent of storage
4. **Application-layer tenant scoping:** No PostgreSQL RLS; simpler and sufficient at launch scale
5. **AWS-native services:** IoT Core, Greengrass, Cognito, ECS/Fargate, Lambda, RDS, S3, CloudFront (no third-party equivalents)
6. **Staged rollouts, manual approval:** Greengrass stages at 10/50/100%; operator manually approves each stage
7. **In-memory rate limiting:** slowapi on single Fargate task; Redis deferred indefinitely
8. **Live end-to-end tests:** Tests use real AWS infrastructure, not mocks

---

## Execution Roadmap

```
Increment 1 (MVP) — Weeks 1–6
  └─ Validates core sensor → dashboard pipeline
  └─ Output: Stable end-to-end system, ~$54/month cost

    Increment 2 (Enterprise) — Weeks 7–10 (starts after MVP stable)
      └─ Adds alerting, RBAC, cost optimization
      └─ Output: Production-ready multi-tenant platform

        Increment 3 (Fleet DevOps) — Weeks 11–15 (starts after Enterprise stable)
          └─ Adds safe OTA, independent rollback, comprehensive testing
          └─ Output: Operationally mature, incident-ready platform
```

**Total estimated timeline:** 15 weeks (3–4 months) from project start to complete fleet-safe system.

---

## File Structure

Paths below are relative to the workspace root. See the [workspace guide](../README.md) and [documentation index](README.md) for navigation.


```
/iot-sensor-mvp/specs/
  ├─ requirements.md      (MVP requirements, EARS format)
  ├─ design.md           (MVP architecture, component design, data flow)
  └─ tasks.md            (30 tasks, 5 waves, dependency graph)

/iot-sensor-enterprise/specs/
  ├─ requirements.md      (Enterprise requirements, depends on MVP)
  ├─ design.md           (Enterprise additions: alerting, RBAC, S3, aggregates)
  └─ tasks.md            (31 tasks, 5 waves)

/iot-sensor-fleet-devops/specs/
  ├─ requirements.md      (Fleet safety & DevOps requirements)
  ├─ design.md           (Greengrass OTA, four pipelines, test suite, runbooks)
  └─ tasks.md            (43 tasks, 6 waves)

/docs/INCREMENTS.md      (This document — high-level overview)

/docs/archive/original-spec/{design,requirements,tasks}.md
  (Original master specs from which increments were derived; kept for reference)
```

---

## Success Criteria

**Increment 1 (MVP) complete when:**
- Edge → MQTT → ingestor → TimescaleDB → REST/WebSocket → dashboard works end-to-end
- Zero data loss test passes (network failure scenario)
- Dashboard displays live readings in real-time

**Increment 2 (Enterprise) complete when:**
- RBAC enforced (Viewer/Admin/Owner roles work)
- Alerting fires on threshold crossing, dispatches SNS/SES
- Continuous aggregates populated and queries route correctly (7d+ requests use rollups)
- S3 raw archive receives every reading in Hive-partitioned format

**Increment 3 (Fleet DevOps) complete when:**
- Greengrass staged deployment (10/50/100%) works end-to-end
- All four CI/CD pipelines auto-deploy on merge (except edge, which is manual)
- Rollback procedures tested and documented for all services
- End-to-end test suite (7 tests) passes in CI

---

## Next Steps

1. **Review** — Stakeholders review all three increment specs (`specs/requirements.md`, `specs/design.md`, `specs/tasks.md`)
2. **Approve** — Product owner and tech lead sign off on scope, dependencies, and timeline
3. **Assign** — Assign owners to Increment 1 Wave 1 tasks (no blocking dependencies)
4. **Track** — Update task.md files as work proceeds; maintain traceability

</content>
