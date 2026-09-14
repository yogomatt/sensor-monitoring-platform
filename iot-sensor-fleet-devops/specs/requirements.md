# Requirements — IoT Sensor Monitoring Platform: Fleet Safety & DevOps

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 3: Fleet Safety & DevOps) |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Scope** | Safe OTA updates, independent rollbacks, comprehensive CI/CD, end-to-end testing |
| **Owner** | Yogo (product owner) |
| **Notation** | EARS (Easy Approach to Requirements Syntax) |
| **Status** | In scope for Increment 3; builds on MVP (Increment 1) and Enterprise (Increment 2) |

---

## How to read this document

Each requirement follows EARS pattern. Increment 3 focuses on operational excellence: fleet safety (staged OTA), deployment independence (per-service rollback), comprehensive testing, and infrastructure validation. Assumes Increments 1 and 2 complete and stable.

---

## Epic 1 — Fleet OTA updates and staged rollouts (Edge)

**User story:** As a platform operator, I want to push updated edge agent code to the fleet safely so that a bad release cannot affect all devices simultaneously.

| ID | Requirement | Notes |
|---|---|---|
| R-FLEET-1 | THE SYSTEM SHALL package the edge agent as a versioned container image stored in a private registry | Docker image; ECR repository; semantic versioning (v1.0.0, v1.0.1, etc.) |
| R-FLEET-2 | WHEN an edge deployment is initiated THE SYSTEM SHALL roll out to the fleet in stages (10% → 50% → 100%) | AWS IoT Greengrass staged deployment; manual trigger at each stage |
| R-FLEET-3 | THE SYSTEM SHALL require an explicit manual trigger to initiate a fleet-wide edge deployment — no deployment SHALL fire automatically on code merge | workflow_dispatch only; never auto-deploy on push/PR merge |
| R-FLEET-4 | WHEN a device is reimaged (sequence_no reset) THE SYSTEM SHALL tolerate the reset without corrupting downstream deduplication | Sequence number wraps; unique constraint includes device timestamp |
| R-ING-3 | WHEN one inbound message path fails (ingestor, archive, alerting) THE SYSTEM SHALL not block or lose data in other paths | Independent Lambda functions and S3 action; no synchronous dependencies |
| R-ING-4 | WHEN the ingestor Lambda fails or is unavailable THE SYSTEM SHALL still preserve the raw reading in permanent storage | S3 raw archive independent of ingestor; failure isolation |

## Epic 2 — Deployment & rollback independence (CI/CD)

**User story:** As a platform operator, I want every layer of the system deployable independently so that a bad API deployment never blocks a frontend fix.

| ID | Requirement | Notes |
|---|---|---|
| R-CICD-1 | THE SYSTEM SHALL deploy edge, Lambda, Fargate, and frontend components through independent pipelines | Four separate GitHub Actions workflows; three repos |
| R-CICD-2 | WHEN a backend or frontend change is merged to the main branch THE SYSTEM SHALL deploy it automatically, without a manual approval gate | Auto-deploy on merge (fast feedback); rollback independent and manual |
| R-CICD-3 | WHEN an edge deployment is not explicitly triggered THE SYSTEM SHALL NOT push any change to devices in the field | workflow_dispatch only; no auto-deploy on edge repo push |
| R-CICD-4 | WHEN a rollback is required for Lambda, Fargate, or frontend THE SYSTEM SHALL revert using each service's native versioning mechanism without requiring a full pipeline re-run | Lambda alias repoint, ECS task-def revision repoint, S3 version restore + CloudFront invalidation |
| R-CICD-5 | THE SYSTEM SHALL retain at least one prior deployable version for each service to enable rollback | Retain exactly 1 prior version (cost optimization); minimum for rollback to work |

## Epic 3 — Comprehensive test coverage (Testing)

**User story:** As a platform operator, I want to validate the entire system (edge, backend, infrastructure) under realistic failure conditions before deploying to production.

| ID | Requirement | Notes |
|---|---|---|
| R-TEST-1 | THE SYSTEM SHALL execute end-to-end tests validating zero data loss when edge network is severed mid-cycle | Kill edge network, verify SQLite buffer holds readings, verify replay on reconnect in correct chronological order |
| R-TEST-2 | THE SYSTEM SHALL execute end-to-end tests validating tenant isolation across API, WebSocket, and database layers | Attempt to retrieve tenant B data as tenant A user; all paths must reject |
| R-TEST-3 | THE SYSTEM SHALL validate ingestor Lambda failure does not prevent S3 raw archive from receiving data | Ingestor Lambda intentionally fails; verify S3 object still created |
| R-TEST-4 | THE SYSTEM SHALL validate device re-imaging (sequence_no reset) does not corrupt downstream deduplication | Reset device counter mid-stream; verify no duplicate readings in database |
| R-TEST-5 | THE SYSTEM SHALL execute load tests generating 500 readings/sec for 10 min, validating zero data loss and <1s query latency at p99 | High-volume stress test; monitor RDS CPU/memory, Lambda duration, S3 throughput |
| R-TEST-6 | THE SYSTEM SHALL validate alerting Lambda evaluates 10,000 devices/sec without dropping alerts | Alert rule evaluation performance; 99% latency < 100ms |
| R-TEST-7 | THE SYSTEM SHALL execute end-to-end tests validating Lambda alias repoint, ECS task-def repoint, and S3 version restore each work independently | Verify rollback procedures before incident |

## Epic 4 — Infrastructure and deployment validation (DevOps)

**User story:** As a platform operator, I want to verify that the infrastructure is properly configured, and that all deployment procedures are documented and tested.

| ID | Requirement | Notes |
|---|---|---|
| R-CICD-6 | THE SYSTEM SHALL provision infrastructure via Infrastructure-as-Code (CDK or Terraform) version-controlled and reviewed | Reproducible, auditable deployments |
| R-CICD-7 | THE SYSTEM SHALL document the manual rollback procedure for each service with step-by-step verification steps | Runbooks; tested under time pressure |

---

## Non-functional requirements (Increment 3 scope)

| ID | Requirement | Notes |
|---|---|---|
| R-NFR-2 | THE SYSTEM SHALL introduce no new infrastructure component without a documented future upgrade trigger | Design principle; design.md lists upgrade conditions |
| R-NFR-3 | THE SYSTEM SHALL prefer AWS-native managed services over third-party equivalents when cost and functionality are comparable | IoT Core, Greengrass, Fargate, Lambda, RDS, S3 all AWS-native |
| R-NFR-4 | THE SYSTEM SHALL support scaling to at least 50 devices and approximately 700 tenants without requiring a redesign of the storage or auth layers | Continuous aggregates and application-layer tenant isolation proven sufficient |

---

## Explicitly out of scope for Increment 3 (deferred indefinitely)

- PostgreSQL row-level security as a database-enforced backstop — indefinite (application-layer isolation sufficient)
- Redis-backed distributed rate limiting — indefinite (slowapi sufficient at launch)
- Internal ops dashboard (Grafana or otherwise) — indefinite (separate product)
- Multi-AZ RDS with automatic failover — indefinite (single-AZ acceptable at scale; cost trade-off explicit)
- dev/staging CI/CD environment tier — indefinite (deferred; use manual feature branches for staging)

---

## Dependencies on Increments 1 and 2

All Increment 3 tasks assume:
- MVP end-to-end pipeline working (Increment 1)
- RBAC, alerting, and S3 raw archive operational (Increment 2)
- All infrastructure stable and repeatable

---

## Next steps

- [ ] Review and accept requirements
- [ ] Proceed to design.md for Fleet Safety & DevOps architecture
- [ ] Proceed to tasks.md for implementation tasks

</content>
