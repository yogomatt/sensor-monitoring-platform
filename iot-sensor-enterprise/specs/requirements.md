# Requirements — IoT Sensor Monitoring Platform: Enterprise Features

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 2: Enterprise) |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Scope** | RBAC, alerts, cost optimization, data retention policies |
| **Owner** | Yogo (product owner) |
| **Notation** | EARS (Easy Approach to Requirements Syntax) |
| **Status** | In scope for Increment 2; builds on MVP (Increment 1) |

---

## How to read this document

Each requirement follows EARS pattern. Increment 2 adds multi-tenant features and operational polish on top of MVP. Assumes Increment 1 (MVP) already complete and stable.

---

## Epic 1 — Role-based access control (API)

**User story:** As a tenant admin, I want to assign different permission levels to my team so that operators can view data but cannot modify alert rules, and viewers cannot see raw readings.

| ID | Requirement | Notes |
|---|---|---|
| R-AUTH-2 | THE SYSTEM SHALL support at least three roles per tenant: Owner, Admin, Viewer | Cognito custom claims; FastAPI dependency checks role |
| R-AUTH-5 | WHEN a client exceeds the configured request rate THE SYSTEM SHALL reject further requests until the window resets | slowapi rate limiter; per-endpoint configuration |

## Epic 2 — Alerting with threshold-based evaluation (Processing)

**User story:** As a tenant operator, I want to define thresholds for specific sensors so that I am automatically notified when a reading crosses a boundary.

| ID | Requirement | Notes |
|---|---|---|
| R-ALERT-1 | THE SYSTEM SHALL allow a tenant to define a threshold rule scoped to a specific device or to all devices of a sensor type | CRUD endpoints; UI in dashboard for Increment 2 |
| R-ALERT-2 | WHEN an inbound reading matches an active alert rule THE SYSTEM SHALL dispatch a notification via the rule's configured channel | SNS for SMS, SES for email; Lambda evaluates rules on each inbound reading |
| R-ALERT-3 | THE SYSTEM SHALL evaluate alert rules without introducing a second, separate data store from the primary operational database | alert_rules table in same RDS; no external rules engine |

## Epic 3 — Time-series storage optimization & retention (Processing/Storage)

**User story:** As a platform operator, I want queries to remain fast as data accumulates, and I want to optimize storage cost by aggregating old data.

| ID | Requirement | Notes |
|---|---|---|
| R-STO-2 | THE SYSTEM SHALL retain 1-minute aggregated rollups for at least 365 days | TimescaleDB continuous aggregate; auto-refresh |
| R-STO-3 | THE SYSTEM SHALL retain 1-hour aggregated rollups indefinitely | Permanent archive rollup for long-term trend analysis |
| R-STO-4 | WHEN a dashboard requests a chart spanning more than 7 days THE SYSTEM SHALL serve the request from a pre-aggregated rollup rather than scanning raw data | Query logic routes to rollup tables; reduces scan cost |
| R-STO-5 | THE SYSTEM SHALL compress raw sensor chunks older than 7 days | TimescaleDB native compression policy; segment by tenant/device/sensor |

## Epic 4 — Raw data archive (Storage)

**User story:** As a tenant, I want a permanent, queryable audit trail of all sensor readings for compliance and forensic analysis.

| ID | Requirement | Notes |
|---|---|---|
| R-STO-6 | THE SYSTEM SHALL retain a permanent, uncompressed raw archive independent of the operational database's retention policy | S3; separate from RDS; Athena-queryable |
| R-STO-7 | THE SYSTEM SHALL partition the raw archive by tenant and time in a convention queryable without manual partition repair | Hive-style: `s3://bucket/raw/{tenant_id}/year=YYYY/month=MM/day=DD/hour=HH/{data}.json` |

---

## Non-functional requirements (Increment 2 scope)

| ID | Requirement | Notes |
|---|---|---|
| R-NFR-4 | THE SYSTEM SHALL support scaling to at least 50 devices and approximately 700 tenants without requiring a redesign of the storage or auth layers | Continuous aggregates keep query latency flat; application-layer tenant isolation efficient |

---

## Explicitly out of scope for Increment 2 (deferred to Increment 3 or indefinitely)

- Fleet-wide OTA updates and staged rollouts — Increment 3
- CI/CD automation pipelines — Increment 3
- PostgreSQL row-level security as a database-enforced backstop — indefinite (trade-off documented in design)
- Redis-backed distributed rate limiting — indefinite (slowapi in-memory sufficient at launch scale)
- Internal ops dashboard — indefinite (separate product concern)

---

## Dependencies on Increment 1 (MVP)

All Increment 2 tasks assume:
- MVP end-to-end pipeline working (sensor → edge → ingestor → dashboard)
- Cognito auth integrated in FastAPI and React
- WebSocket live updates functional
- TimescaleDB hypertable and basic schema in place

---

## Next steps

- [ ] Review and accept requirements
- [ ] Proceed to design.md for Enterprise Features architecture
- [ ] Proceed to tasks.md for implementation tasks

</content>
