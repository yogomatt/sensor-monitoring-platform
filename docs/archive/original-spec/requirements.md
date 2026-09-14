# Requirements — IoT Sensor Monitoring Platform

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Design-First variant — architecture already exists via ADR-001–007) |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Owner** | Yogo (product owner) |
| **Notation** | EARS (Easy Approach to Requirements Syntax) |
| **Status** | Derived from Accepted ADRs — requirements back-filled from existing design, not greenfield |

---

## How to read this document

Each requirement follows EARS pattern:
`WHEN [condition/event] THE SYSTEM SHALL [expected behavior]`
or for invariants: `THE SYSTEM SHALL [always-true behavior]`

Requirements are grouped by user story, tagged with an ID (`R-{area}-{n}`), and cross-referenced to the ADR that already resolved the underlying design decision. This spec was built **design-first**: the architecture (ADR-001–007) predates this requirements doc, so each requirement below is traceable backward to an existing decision rather than forward to one still open.

---

## Epic 1 — Sensor data collection (Edge)

**User story:** As a tenant operator, I want sensor readings collected reliably from my devices so that I never lose visibility into my equipment, even during network outages.

| ID | Requirement | Source ADR |
|---|---|---|
| R-EDGE-1 | WHEN a sensor reading is captured THE SYSTEM SHALL write it to local durable storage before attempting network publish | ADR-002 |
| R-EDGE-2 | WHEN the edge device loses network connectivity THE SYSTEM SHALL continue capturing and locally buffering readings without data loss | ADR-002 |
| R-EDGE-3 | WHEN connectivity is restored THE SYSTEM SHALL replay all pending buffered readings in chronological order | ADR-002 |
| R-EDGE-4 | WHEN the local buffer reaches its configured row cap THE SYSTEM SHALL drop the oldest unpublished rows and log the eviction as an error | ADR-002 |
| R-EDGE-5 | WHEN a sensor read fails THE SYSTEM SHALL publish a structured error event rather than silently skipping the cycle | ADR-002 |
| R-EDGE-6 | THE SYSTEM SHALL emit a heartbeat on a fixed interval containing agent version, buffer depth, and uptime | ADR-002 |
| R-EDGE-7 | THE SYSTEM SHALL publish every message with a per-device monotonically increasing sequence number | ADR-002 |
| R-EDGE-8 | WHEN a device is reimaged THE SYSTEM SHALL tolerate the resulting sequence-number reset without corrupting downstream deduplication | ADR-002, ADR-003 |

## Epic 2 — Fleet & OTA management (Edge)

**User story:** As a platform operator, I want to update edge agent software across the fleet safely so that a bad release cannot brick devices in the field.

| ID | Requirement | Source ADR |
|---|---|---|
| R-FLEET-1 | THE SYSTEM SHALL package the edge agent as a versioned container image stored in a private registry | ADR-001 |
| R-FLEET-2 | WHEN an edge deployment is initiated THE SYSTEM SHALL roll out to the fleet in stages (10% → 50% → 100%) | ADR-001, ADR-007 |
| R-FLEET-3 | THE SYSTEM SHALL require an explicit manual trigger to initiate a fleet-wide edge deployment — no deployment SHALL fire automatically on code merge | ADR-007 |
| R-FLEET-4 | WHEN a device is provisioned THE SYSTEM SHALL authenticate it via a unique X.509 certificate over mutual TLS | ADR-002 |

## Epic 3 — Reliable, deduplicated ingestion (Ingestion)

**User story:** As a platform operator, I want every reading ingested exactly once in the canonical store, regardless of network retries or edge replay, so dashboards and alerts are never double-counted.

| ID | Requirement | Source ADR |
|---|---|---|
| R-ING-1 | THE SYSTEM SHALL deliver MQTT messages from edge to cloud with at-least-once guarantee (QoS 1) | ADR-003 |
| R-ING-2 | WHEN a duplicate reading arrives (via QoS resend or edge replay) THE SYSTEM SHALL discard it without creating a duplicate row in the canonical store | ADR-003 |
| R-ING-3 | THE SYSTEM SHALL route each inbound message to the ingestor, raw archive, and alerting paths independently, such that failure in one path SHALL NOT block or lose data in another | ADR-003 |
| R-ING-4 | WHEN the ingestor Lambda fails or is unavailable THE SYSTEM SHALL still preserve the raw reading in permanent storage | ADR-003, ADR-004 |
| R-ING-5 | THE SYSTEM SHALL perform ingestor deduplication statelessly, without depending on a separate external dedup store | ADR-003 |

## Epic 4 — Time-series storage & retention (Processing/Storage)

**User story:** As a tenant, I want historical sensor data available at the right resolution for the right length of time, without the platform incurring unnecessary storage cost.

| ID | Requirement | Source ADR |
|---|---|---|
| R-STO-1 | THE SYSTEM SHALL retain raw sensor readings for at least 30 days | ADR-004 |
| R-STO-2 | THE SYSTEM SHALL retain 1-minute aggregated rollups for at least 365 days | ADR-004 |
| R-STO-3 | THE SYSTEM SHALL retain 1-hour aggregated rollups indefinitely | ADR-004 |
| R-STO-4 | WHEN a dashboard requests a chart spanning more than the raw-retention window THE SYSTEM SHALL serve the request from a pre-aggregated rollup rather than scanning raw data | ADR-004 |
| R-STO-5 | THE SYSTEM SHALL compress raw sensor chunks older than 7 days | ADR-004 |
| R-STO-6 | THE SYSTEM SHALL retain a permanent, uncompressed raw archive independent of the operational database's retention policy | ADR-004 |
| R-STO-7 | THE SYSTEM SHALL partition the raw archive by tenant and time in a convention queryable without manual partition repair | ADR-004 |

## Epic 5 — Multi-tenant data isolation (Storage/API)

**User story:** As a tenant, I want assurance that I can never see another tenant's data, under any circumstances.

| ID | Requirement | Source ADR |
|---|---|---|
| R-TEN-1 | THE SYSTEM SHALL tag every sensor reading, device record, heartbeat, error, and alert rule with a tenant identifier at the point of creation | ADR-002, ADR-004 |
| R-TEN-2 | WHEN the API executes any data query THE SYSTEM SHALL scope it to the tenant identifier extracted from the caller's authenticated session, never from client-supplied input | ADR-005 |
| R-TEN-3 | THE SYSTEM SHALL derive the tenant identifier for API requests from a signed JWT claim | ADR-005 |

## Epic 6 — Authenticated, role-based dashboard access (API)

**User story:** As a tenant admin, I want to control who on my team can view vs. manage sensor data and alert rules.

| ID | Requirement | Source ADR |
|---|---|---|
| R-AUTH-1 | THE SYSTEM SHALL require authentication for all API and WebSocket access to tenant data | ADR-005 |
| R-AUTH-2 | THE SYSTEM SHALL support at least three roles per tenant: Owner, Admin, Viewer | ADR-005 |
| R-AUTH-3 | WHEN a WebSocket connection is established THE SYSTEM SHALL validate the caller's JWT before streaming any tenant data | ADR-005 |
| R-AUTH-4 | THE SYSTEM SHALL avoid logging WebSocket authentication tokens in access logs | ADR-005 |
| R-AUTH-5 | WHEN a client exceeds the configured request rate THE SYSTEM SHALL reject further requests until the window resets | ADR-005 |

## Epic 7 — Alerting (Processing)

**User story:** As a tenant operator, I want to be notified when a sensor reading crosses a threshold I've configured, so I can react before a problem escalates.

| ID | Requirement | Source ADR |
|---|---|---|
| R-ALERT-1 | THE SYSTEM SHALL allow a tenant to define a threshold rule scoped to a specific device or to all devices of a sensor type | ADR-004 |
| R-ALERT-2 | WHEN an inbound reading or error event matches an active alert rule THE SYSTEM SHALL dispatch a notification via the rule's configured channel | ADR-004 |
| R-ALERT-3 | THE SYSTEM SHALL evaluate alert rules without introducing a second, separate data store from the primary operational database | ADR-004 |

## Epic 8 — Customer-facing dashboard (Frontend)

**User story:** As a tenant user, I want a branded, real-time dashboard I can trust to reflect current device state without paying per-viewer.

| ID | Requirement | Source ADR |
|---|---|---|
| R-FE-1 | THE SYSTEM SHALL render tenant-specific branding without incurring a per-viewer licensing cost | ADR-006 |
| R-FE-2 | THE SYSTEM SHALL serve the dashboard exclusively over HTTPS with a custom domain | ADR-006 |
| R-FE-3 | THE SYSTEM SHALL support client-side routing (SPA) with correct fallback behavior on direct URL access | ADR-006 |
| R-FE-4 | WHEN a dashboard is open THE SYSTEM SHALL push live sensor updates to the client without requiring manual refresh | ADR-005 (WebSocket), ADR-006 |

## Epic 9 — Deployment & rollback safety (CI/CD)

**User story:** As a platform operator, I want every layer of the system deployable and revertible quickly and independently, so a bad release in one area never blocks recovery in another.

| ID | Requirement | Source ADR |
|---|---|---|
| R-CICD-1 | THE SYSTEM SHALL deploy edge, Lambda, Fargate, and frontend components through independent pipelines | ADR-007 |
| R-CICD-2 | WHEN a backend or frontend change is merged to the main branch THE SYSTEM SHALL deploy it automatically, without a manual approval gate | ADR-007 |
| R-CICD-3 | WHEN an edge deployment is not explicitly triggered THE SYSTEM SHALL NOT push any change to devices in the field | ADR-007 |
| R-CICD-4 | WHEN a rollback is required for Lambda, Fargate, or frontend THE SYSTEM SHALL revert using each service's native versioning mechanism without requiring a full pipeline re-run | ADR-007 |
| R-CICD-5 | THE SYSTEM SHALL retain at least one prior deployable version for each service to enable rollback | ADR-007 |

---

## Non-functional requirements

| ID | Requirement | Source ADR |
|---|---|---|
| R-NFR-1 | THE SYSTEM SHALL operate at a total infrastructure cost of approximately $54/month at a 10-device, single-digit-tenant launch scale | ADR-004, ADR-005, ADR-006 |
| R-NFR-2 | THE SYSTEM SHALL introduce no new infrastructure component without a documented future upgrade trigger | All ADRs (design principle) |
| R-NFR-3 | THE SYSTEM SHALL prefer AWS-native managed services over third-party equivalents when cost and functionality are comparable | ADR-004, ADR-006 |
| R-NFR-4 | THE SYSTEM SHALL support scaling to at least 50 devices and approximately 700 tenants without requiring a redesign of the storage or auth layers | ADR-004, ADR-005 |

---

## Explicitly out of scope (do not implement without a new spec)

- Public/partner API tiers (deferred behind API Gateway trigger, ADR-005)
- PostgreSQL row-level security as a DB-enforced tenant isolation backstop (deferred, ADR-005)
- Redis-backed distributed rate limiting (deferred, ADR-005)
- Multi-AZ RDS / high-availability database (deferred, ADR-004)
- Kinesis-based stream buffering (explicitly removed, ADR-003 — do not reintroduce without a new design session)
- Internal cross-tenant ops dashboard (Grafana or otherwise) — separate from the customer-facing product (ADR-006)
- dev/staging CI/CD environment tier (deferred, ADR-007)

---

## Requirement → ADR coverage check

Every requirement above traces to an Accepted ADR. No requirement in this document introduces new scope beyond ADR-001–007; this spec is a re-expression of already-approved design in EARS form, intended to drive `design.md` and `tasks.md` generation in AI-assisted tools (Cursor, Kiro) without re-litigating settled decisions.

## Open questions

- None — all requirements trace to Accepted ADRs with no unresolved ambiguity.

## Next steps

- [ ] Generate `design.md` from this requirements set (see companion file)
- [ ] Generate `tasks.md` with dependency-ordered implementation tasks (see companion file)
- [ ] If any new feature is proposed later, add a new Epic here first — do not skip straight to design or tasks
