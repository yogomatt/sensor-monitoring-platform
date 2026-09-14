# Requirements — IoT Sensor Monitoring Platform: MVP

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 1: MVP) |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Scope** | End-to-end sensor → dashboard pipeline, zero data loss, no alerting/fleet staging/complex auth |
| **Owner** | Yogo (product owner) |
| **Notation** | EARS (Easy Approach to Requirements Syntax) |
| **Status** | In scope for MVP; see companion design.md and tasks.md |

---

## How to read this document

Each requirement follows EARS pattern:
`WHEN [condition/event] THE SYSTEM SHALL [expected behavior]`
or for invariants: `THE SYSTEM SHALL [always-true behavior]`

Requirements are grouped by epic and tagged with an ID (`R-{area}-{n}`). Only requirements in scope for MVP Increment 1 are included; Increments 2 and 3 add RBAC, alerting, and fleet safety respectively.

---

## Epic 1 — Sensor data collection (Edge)

**User story:** As a tenant operator, I want sensor readings collected reliably from my devices so that I never lose visibility into my equipment, even during network outages.

| ID | Requirement | Notes |
|---|---|---|
| R-EDGE-1 | WHEN a sensor reading is captured THE SYSTEM SHALL write it to local durable storage before attempting network publish | Write-ahead pattern; prevents data loss on crash |
| R-EDGE-2 | WHEN the edge device loses network connectivity THE SYSTEM SHALL continue capturing and locally buffering readings without data loss | Buffer survives restarts; WAL mode enforces durability |
| R-EDGE-3 | WHEN connectivity is restored THE SYSTEM SHALL replay all pending buffered readings in chronological order | Chronological order required for dashboard consistency |
| R-EDGE-7 | THE SYSTEM SHALL publish every message with a per-device monotonically increasing sequence number | Downstream dedup key; resets on reimage (handled in design) |

## Epic 2 — Reliable, deduplicated ingestion (Ingestion)

**User story:** As a platform operator, I want every reading ingested exactly once in the canonical store, regardless of network retries or edge replay, so dashboards are never double-counted.

| ID | Requirement | Notes |
|---|---|---|
| R-ING-1 | THE SYSTEM SHALL deliver MQTT messages from edge to cloud with at-least-once guarantee (QoS 1) | AWS IoT Core native; ensures no message is silently lost |
| R-ING-2 | WHEN a duplicate reading arrives (via QoS resend or edge replay) THE SYSTEM SHALL discard it without creating a duplicate row in the canonical store | Idempotent upsert in database layer |
| R-ING-5 | THE SYSTEM SHALL perform ingestor deduplication statelessly, without depending on a separate external dedup store | No Redis or separate DynamoDB for dedup; use database-layer unique constraints |

## Epic 3 — Time-series storage & retention (Processing/Storage)

**User story:** As a tenant, I want historical sensor data available for dashboards without the platform incurring unnecessary complexity.

| ID | Requirement | Notes |
|---|---|---|
| R-STO-1 | THE SYSTEM SHALL retain raw sensor readings for at least 30 days | Retention policy on hypertable; purges older data automatically |

## Epic 4 — Multi-tenant data isolation (Storage/API)

**User story:** As a tenant, I want assurance that I can never see another tenant's data, under any circumstances.

| ID | Requirement | Notes |
|---|---|---|
| R-TEN-1 | THE SYSTEM SHALL tag every sensor reading and device record with a tenant identifier at the point of creation | Tenant ID baked into MQTT payload and database rows |
| R-TEN-2 | WHEN the API executes any data query THE SYSTEM SHALL scope it to the tenant identifier extracted from the caller's authenticated session, never from client-supplied input | No tenant_id parameter exposed in REST API; enforced via JWT claim |
| R-TEN-3 | THE SYSTEM SHALL derive the tenant identifier for API requests from a signed JWT claim | Cognito provides JWT; FastAPI validates and extracts claim |

## Epic 5 — Authenticated dashboard access (API)

**User story:** As a tenant operator, I want a dashboard protected by authentication so that only authorized users can view my sensor data.

| ID | Requirement | Notes |
|---|---|---|
| R-AUTH-1 | THE SYSTEM SHALL require authentication for all API and WebSocket access to tenant data | JWT bearer token on REST, JWT query param on WS (browser limitation) |

## Epic 6 — Customer-facing dashboard (Frontend)

**User story:** As a tenant user, I want a branded, real-time dashboard I can trust to reflect current device state.

| ID | Requirement | Notes |
|---|---|---|
| R-FE-2 | THE SYSTEM SHALL serve the dashboard exclusively over HTTPS with a custom domain | CloudFront + ACM cert + S3 static host |
| R-FE-4 | WHEN a dashboard is open THE SYSTEM SHALL push live sensor updates to the client without requiring manual refresh | WebSocket connection to FastAPI; automatic push on new readings |

---

## Non-functional requirements (MVP scope)

| ID | Requirement | Notes |
|---|---|---|
| R-NFR-1 | THE SYSTEM SHALL operate at a total infrastructure cost of approximately $54/month at a 10-device, single-digit-tenant launch scale | Single-AZ RDS, single Fargate task, minimal compute |

---

## Explicitly out of scope for MVP (deferred to Increment 2 or 3)

- Role-based access control (Owner/Admin/Viewer) — Increment 2
- Alert rules and threshold-based notifications — Increment 2
- Fleet-wide OTA updates and staged rollouts — Increment 3
- Data retention policies beyond 30d raw — Increment 2
- Rate limiting — Increment 2
- CI/CD pipelines — Increment 3
- Row-level security at database layer — deferred indefinitely
- Redis-backed distributed rate limiting — deferred indefinitely
- Internal ops dashboard — deferred indefinitely

---

## Next steps

- [ ] Review and accept requirements
- [ ] Proceed to design.md for MVP architecture
- [ ] Proceed to tasks.md for implementation tasks

</content>
