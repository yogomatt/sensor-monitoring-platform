# ADR-005 — API layer: auth/RBAC, tenant isolation, rate limiting, WebSocket auth

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-07-19 |
| **Deciders** | Yogo (product owner) |
| **Builds on** | ADR-001 — IoT platform architecture overview; ADR-004 — Processing & storage layer |

---

## Context

The API layer was directionally established in the original architecture notes (2026-06-23): FastAPI on ECS/Fargate behind an ALB, JWT + Cognito for auth, no API Gateway at launch. Five concrete decisions remained open:

1. Framework choice (FastAPI vs. alternatives)
2. API Gateway inclusion vs. deferral
3. Tenant query isolation strategy
4. Auth/RBAC implementation and Cognito pricing tier
5. Rate limiting and WebSocket authentication design

---

## Decision 1 — FastAPI on ECS/Fargate

### Decision

Confirm **FastAPI (Python)** as the API framework, over Node.js.

### Rationale

- **Language consistency across the stack** — edge agent, Lambda ingestor, and alerting logic are already Python; Pydantic schemas for sensor payloads (ADR-002) can be shared directly with the API layer
- **Native async performance** — Starlette/ASGI gives comparable throughput to Node.js for I/O-bound workloads (DB queries, WebSocket connections)
- **Automatic OpenAPI docs** — useful groundwork for eventual public/partner API tiers
- **ML/analytics ecosystem** — if threshold-based alerting evolves into anomaly detection, Python's ecosystem integrates with no cross-language bridge

### Alternatives considered

| Option | Reason rejected |
|---|---|
| Node.js | Same-language-as-frontend benefit doesn't outweigh losing Python consistency with edge/Lambda; WebSocket ecosystem maturity advantage is marginal for this use case |

---

## Decision 2 — API Gateway deferred at launch

### Decision

**Confirmed.** No API Gateway at launch. FastAPI + ALB handles auth, rate limiting, CORS, and WebSockets directly.

### Rationale

- Pragmatic simplification for early commercial launch — avoids a second routing/auth layer for a 10-device, single-digit-tenant deployment
- Add API Gateway later when: (a) public API tiers are needed, (b) partner integrations are required, (c) WAF/DDoS compliance is mandated

### Out of scope

- API Gateway re-introduction trigger — no threshold analysis performed, consistent with the Kinesis deferral pattern in ADR-003

---

## Decision 3 — Tenant query isolation: application-layer enforcement

### Decision

**Confirmed.** Tenant isolation enforced at the query layer in FastAPI (`WHERE tenant_id = $1`), not via PostgreSQL row-level security (RLS).

### Rationale

- `tenant_id` is already present in every TimescaleDB table (ADR-004) and every JWT claim (Decision 4 below) — the API layer already has what it needs to scope every query without additional DB-side policy configuration
- Avoids RLS session-variable plumbing (`SET app.current_tenant`) on every connection in a pooled/serverless-adjacent (Lambda + Fargate) environment, which adds operational complexity disproportionate to a single-digit tenant count at launch
- Consistent with "simplicity over over-engineering" design value

### Alternatives considered

| Option | Reason rejected |
|---|---|
| PostgreSQL RLS | Defense-in-depth benefit is real, but adds session-variable management complexity across Lambda + Fargate connection pools; revisit if tenant count or compliance requirements grow |

### Out of scope

- RLS as a defense-in-depth layer — may be revisited post-launch if compliance requirements (e.g. SOC 2) demand it

---

## Decision 4 — Auth/RBAC via AWS Cognito (Essentials tier)

### Decision

Use **AWS Cognito User Pools, Essentials tier**, for user identity, authentication, and role-based access control (Owner / Admin / Viewer).

### Architecture

```
User login → Cognito User Pool → JWT (access + id token, RS256)
                                        │
                                        ▼
                    FastAPI validates JWT against Cognito JWKS (cached)
                                        │
                                        ▼
        Extract claims: user_id, custom:tenant_id, custom:role
                                        │
                                        ▼
      FastAPI dependency enforces role + injects tenant_id into query scope
```

- Custom attributes `custom:tenant_id` and `custom:role` attached per user
- JWT validation is stateless — no DB hit per request
- `tenant_id` claim feeds directly into the Decision 3 app-layer isolation — scoping comes from the token, not client-supplied input

### Rationale

- Native AWS service — no separate auth infrastructure to run or patch; matches the platform's AWS ecosystem coherence value
- Essentials tier (over Lite) adds Managed Login, passwordless/passkey support, and refresh token rotation at the same free-tier threshold and MAU rate as Lite — worth the parity pricing
- Offloads password storage, MFA, and account recovery entirely

### Pricing (verified July 2026, aws.amazon.com/cognito/pricing)

- Free tier: **10,000 MAUs/month** (direct/social sign-in, Lite or Essentials tier) — does not expire
- Beyond free tier: **$0.015/MAU** (Essentials)
- SMS (MFA) billed separately via SNS; email verification billed separately via SES (covered by SES's own free tier at this scale)

### Cost estimate for this platform

MAUs here are **human dashboard users** (Owner/Admin/Viewer), not devices or sensor readings.

| Scenario | Est. MAUs | Cost |
|---|---|---|
| Launch: 1–3 tenants × 2–5 users | 5–15 | $0/month |
| Growth: 50 tenants × 5 users | 250 | $0/month |
| Growth: 700 tenants × ~15 users avg | ~10,000+ | First MAU charges appear |

Cognito is effectively **$0/month at launch scale** and stays free through a wide range of multi-tenant growth. No impact on the ~$67/month platform total (ADR-004).

### Alternatives considered

| Option | Reason rejected |
|---|---|
| Self-rolled JWT (FastAPI + passlib/python-jose) | Full control, but owns password storage, reset flows, MFA, and security hardening — disproportionate build/maintain cost at this scale |
| Auth0 / Clerk | Excellent DX, but outside the AWS account; per-MAU pricing and vendor dependency break ecosystem coherence |
| Cognito Identity Pools (IAM-based) | Unneeded — no direct frontend-to-AWS-resource access pattern exists in this architecture |

---

## Decision 5 — Rate limiting and WebSocket authentication

### Rate limiting: slowapi (in-memory)

**Decision:** Use **slowapi** (in-memory token bucket, per Fargate task) at launch.

**Purpose:** Caps requests per user/IP in a given window (e.g. 100 req/min) to prevent a buggy or malicious client from degrading the API for other tenants, and to keep Fargate/RDS costs predictable.

**Rationale:**
- At launch scale (low Fargate replica count), in-memory counters are close enough to accurate to be useful
- Zero additional infrastructure or cost
- Matches "simplicity over over-engineering" — a shared Redis-backed limiter is unnecessary until replica count grows

**Upgrade trigger:** Move to Redis-backed slowapi (via ElastiCache, ~$12–15/month) once Fargate task count exceeds 1–2 replicas, at which point in-memory counters under-count real per-user traffic across instances. Mirrors the RDS Proxy "revisit if it becomes a bottleneck" pattern from ADR-004.

### WebSocket authentication: query-parameter token

**Decision:** Authenticate WebSocket connections via **JWT passed as a query parameter** (`wss://api/ws?token=<jwt>`), validated against Cognito JWKS on connection.

**Rationale:**
- Browsers cannot set custom headers on the WS handshake, so the JWT must travel via URL, cookie, or a post-connection message
- Query-param token is the simplest of the viable options and matches the platform's simplicity value
- Mitigate log-leakage risk by disabling ALB/CloudWatch access logging of query strings for the WS endpoint; rely on Cognito's short token expiry to limit exposure window

### Alternatives considered

| Option | Reason rejected |
|---|---|
| slowapi + Redis (ElastiCache) | Adds infra cost unneeded at single/low-replica Fargate scale; deferred as documented upgrade trigger |
| AWS WAF rate-based rules | IP-based, not per-tenant/per-user — too blunt for API quota enforcement (still viable later as a DDoS layer, orthogonal to this decision) |
| API Gateway usage plans | Off the table — API Gateway deferred per Decision 2 |
| Cookie-based WS auth | Avoids URL leakage but adds CORS/cookie-domain complexity between CloudFront (frontend) and ALB (API) |
| Ticket exchange pattern (short-lived WS ticket) | Most secure option, avoids exposing the JWT at all — but disproportionate complexity for a 10-tenant launch; candidate for revisit if compliance needs tighten |
| First-message auth (connect unauthenticated, send token first) | Avoids URL/log leakage, but adds client-side complexity and a brief unauthenticated connection window |

---

## Consequences

### Positive
- Single-language stack (Python) from edge to API simplifies schema sharing and reduces context-switching
- Cognito Essentials is effectively free at launch and scales gracefully; no separate auth infrastructure to operate
- App-layer tenant isolation requires no additional DB configuration — `tenant_id` already flows from JWT claim to query scope
- Rate limiting and WebSocket auth both ship with zero additional infrastructure cost at launch
- API Gateway deferral keeps the request path simple: client → CloudFront (frontend) / ALB (API) → FastAPI

### Negative / trade-offs
- In-memory rate limiting under-counts traffic once Fargate scales beyond 1 replica — requires a follow-up migration to Redis-backed limiting
- Query-param WebSocket tokens carry a log-leakage risk if access logging isn't explicitly disabled for the WS endpoint
- App-layer tenant isolation (vs. RLS) relies on discipline in every query — no DB-enforced backstop if a query is written without the `tenant_id` filter
- No API Gateway means no built-in WAF/DDoS layer at launch — acceptable at current scale, revisit at growth

### Out of scope for this ADR
- Redis-backed rate limiting implementation detail (deferred, trigger: >1–2 Fargate replicas)
- Ticket-exchange WebSocket auth (deferred, trigger: compliance/security requirements tighten)
- PostgreSQL RLS as defense-in-depth (deferred, trigger: compliance requirements e.g. SOC 2)
- API Gateway re-introduction trigger (explicitly out of scope, consistent with ADR-003's Kinesis precedent)
- Cognito Lambda trigger implementation (pre-token generation, custom attribute assignment logic)

---

## References

- ADR-001 — IoT platform architecture overview (2026-06-23)
- ADR-002 — Edge layer: MQTT topic structure and SQLite offline buffer (2026-06-24)
- ADR-003 — Ingestion layer: drop Kinesis, MQTT QoS 1, ingestor deduplication (2026-06-24)
- ADR-004 — Processing & storage layer: RDS instance, schema, alerting store, S3 naming (2026-07-18)
- AWS Cognito pricing documentation (verified July 2026, aws.amazon.com/cognito/pricing)
- AWS IoT Core / FastAPI / slowapi documentation
