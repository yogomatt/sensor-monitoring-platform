# Tasks — IoT Sensor Monitoring Platform: Enterprise Features

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 2: Enterprise) — Implementation phase |
| **Version** | 1.1 |
| **Date** | 2026-09-23 |
| **Derived from** | `design.md` Enterprise v1.1 |
| **Depends on** | All MVP tasks (Increment 1) completed and passing |
| **Status** | Not started — all tasks pending |

Storage scope follows [ADR-008](../../docs/adr/ADR-008-native-postgresql-storage.md): native PostgreSQL partitioning, manual purging, no compression or rollups in any increment.

---

## How to read this document

Each task lists its **Requirement(s)**, **Depends on** (task IDs that must complete first), and **Status**. MVP completion is a prerequisite; all Increment 2 tasks reference prior Increment 1 task IDs.

---

## Wave 1 — Schema and alerting infrastructure

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-E2-1.1 | Create `alert_rules` table in RDS: (id, tenant_id, device_id, sensor_type, threshold_*, operator, channel_type, channel_target, active) | R-ALERT-1 | MVP complete | pending |
| T-E2-1.5 | Provision S3 bucket for raw archive (separate from frontend bucket); enable Hive-style partition discovery | R-STO-6, R-STO-7 | — | pending |
| T-E2-1.6 | Configure S3 lifecycle: Standard (0–90d) → Glacier Instant (90d–10y), no expiry | R-STO-6 | T-E2-1.5 | pending |
| T-E2-1.7 | Provision SNS topic and SES sending limit per tenant (for alert dispatch) | R-ALERT-2 | — | pending |
| T-E2-1.8 | Add Cognito custom attribute `custom:role` to User Pool; update user schema | R-AUTH-2 | MVP complete | pending |

---

## Wave 2 — Lambda alerting and Cognito RBAC

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-E2-2.1 | Implement Alerting Lambda: parse inbound reading, query `alert_rules`, evaluate thresholds, dispatch SNS/SES | R-ALERT-2, R-ALERT-3 | T-E2-1.1, T-E2-1.7 | pending |
| T-E2-2.2 | Configure IoT Rules Engine: add S3 action to write raw readings (Hive-style partitioned) in parallel with ingestor Lambda | R-STO-6, R-STO-7 | T-E2-1.5, MVP complete | pending |
| T-E2-2.3 | Update IoT Rules Engine: add Alerting Lambda action on `status/errors` topic | R-ALERT-2 | T-E2-2.1, MVP complete | pending |
| T-E2-2.4 | Implement FastAPI role authorization dependency: check `custom:role` claim, enforce Owner/Admin/Viewer permissions | R-AUTH-2 | T-E2-1.8 | pending |
| T-E2-2.5 | Add role-scoped WebSocket message filtering: WebSocket clients only receive readings from devices their role allows | R-AUTH-2 | T-E2-2.4, MVP complete | pending |

---

## Wave 3 — FastAPI enhancements

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-E2-3.1 | Integrate slowapi rate limiter on FastAPI: 100 req/min per authenticated user by default | R-AUTH-5 | MVP complete | pending |
| T-E2-3.3 | Implement alert rule CRUD endpoints: POST/GET/PUT/DELETE /api/v1/alert-rules (role-protected: Admin/Owner only) | R-ALERT-1 | T-E2-1.1, T-E2-2.4 | pending |
| T-E2-3.4 | Update existing REST endpoints to respect rate limiter and role authorization | R-AUTH-2, R-AUTH-5 | T-E2-3.1, T-E2-2.4 | pending |
| T-E2-3.5 | Deploy updated FastAPI to Fargate; verify rate limiter and role checks in logs | R-AUTH-2, R-AUTH-5 | T-E2-3.1, T-E2-3.3, T-E2-3.4 | pending |

---

## Wave 4 — Frontend dashboard enhancements

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-E2-4.1 | Update React dashboard to display user role and handle 403 Forbidden responses gracefully | R-AUTH-2 | MVP complete | pending |
| T-E2-4.2 | Build alert rule management UI (CRUD for alert_rules, role-restricted to Admin/Owner) | R-ALERT-1 | T-E2-3.3 | pending |
| T-E2-4.4 | Add visual indicator in dashboard when rate limit is approaching (429 handling) | R-AUTH-5 | T-E2-4.1 | pending |
| T-E2-4.5 | Deploy updated React app to S3 + CloudFront invalidation | — | T-E2-4.1, T-E2-4.2, T-E2-4.4 | pending |

---

## Wave 5 — Integration testing and documentation

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-E2-5.1 | End-to-end test: verify role-based access control (Viewer cannot POST alert rules, Owner can) | R-AUTH-2 | T-E2-3.3, T-E2-4.2 | pending |
| T-E2-5.2 | End-to-end test: alert threshold crossing, verify SNS notification dispatched | R-ALERT-2 | T-E2-2.1 | pending |
| T-E2-5.4 | Verify S3 raw archive receives every reading in correct Hive-style partition | R-STO-6, R-STO-7 | T-E2-2.2 | pending |
| T-E2-5.5 | Load test: Athena query on raw archive (1M+ readings), verify sub-5s latency | R-STO-7 | T-E2-5.4 | pending |
| T-E2-5.6 | Stress test: 500 req/sec for 5 min, verify rate limiter rejects excess and recovers gracefully | R-AUTH-5 | T-E2-3.1 | pending |
| T-E2-5.7 | Document alert rule configuration (threshold operators, channel types, best practices) | R-ALERT-1 | T-E2-3.3 | pending |

---

## Retired tasks (ADR-008)

T-E2-1.2, T-E2-1.3, T-E2-1.4, T-E2-3.2, T-E2-4.3, T-E2-5.3, and T-E2-5.8 are removed with R-STO-2 through R-STO-5. They covered rollups, rollup retention/query routing, compression, and associated verification/documentation. IDs remain reserved; these tasks are excluded from progress totals and are not completed or deferred work.

## Explicitly deferred (do not schedule without a new spec)

- Automatic operational database purging — only if performance studies justify a future feature
- Fleet OTA updates and staged rollouts — Increment 3
- CI/CD automation pipelines — Increment 3
- Multi-AZ RDS failover — indefinite
- PostgreSQL row-level security (RLS) — indefinite (trade-off documented in design)
- Redis-backed distributed rate limiting — indefinite (slowapi sufficient at launch)
- Internal ops dashboard (Grafana or otherwise) — indefinite

---

## Progress summary

| Wave | Total tasks | Done | In progress | Pending |
|---|---|---|---|---|
| 1 | 5 | 0 | 0 | 5 |
| 2 | 5 | 0 | 0 | 5 |
| 3 | 4 | 0 | 0 | 4 |
| 4 | 4 | 0 | 0 | 4 |
| 5 | 6 | 0 | 0 | 6 |
| **Total** | **24** | **0** | **0** | **24** |

---

## Next steps

- [ ] Ensure all MVP (Increment 1) tasks are complete and stable
- [ ] Assign owners to Wave 1 tasks (can start immediately after MVP)
- [ ] Assign owners to subsequent waves (blocked on prior wave completion)
- [ ] Update task status as work proceeds

</content>
