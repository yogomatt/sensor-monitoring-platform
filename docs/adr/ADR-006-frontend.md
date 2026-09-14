# ADR-006 — Frontend layer: React + Recharts, S3 + CloudFront hosting

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-07-20 |
| **Deciders** | Yogo (product owner) |
| **Builds on** | ADR-001 — IoT platform architecture overview; ADR-004 — Processing & storage layer; ADR-005 — API layer |

---

## Context

The original architecture decisions (2026-06-23) tentatively selected React + Recharts for the dashboard frontend but left one question explicitly open: stick with a custom React app for full branding control, or adopt Grafana for faster time-to-market on dashboards. Unlike the edge, ingestion, processing/storage, and API layers, this question was never formally closed with a dedicated design session — it was carried forward as an assumed default.

Two concrete decisions needed to be made:

1. Custom React + Recharts application vs. Amazon Managed Grafana (AMG)
2. Whether to include CloudFront in front of S3 at launch, given a geographically concentrated initial user base

---

## Decision 1 — React + Recharts over Amazon Managed Grafana

### Decision

Build a custom dashboard frontend in **React + Recharts**. Do not adopt Amazon Managed Grafana for the customer-facing product.

### Rationale

**Cost model mismatch is the deciding factor.** AMG bills per human user, not per tenant or flat rate:

| Component | AMG pricing |
|---|---|
| Editor license | $9/user/month |
| Viewer license | $5/user/month |
| Enterprise plugins (needed for white-labeling) | +$45/user/month |

At launch scale (1–3 tenants × 2–5 users), this projects to **$25–75/month** — comparable to or exceeding the entire rest of the platform's ~$67/month cost. This cost scales linearly with customer growth, unlike the flat-rate hosting cost of a custom React app. This directly conflicts with the platform's cost-efficiency design value and its already-adopted Cognito auth model, which is free up to 10,000 MAUs.

**Branding and multi-tenant UI fit:**
- Grafana's UI cannot be white-labeled without the Enterprise tier — unacceptable for a commercial multi-tenant product where each tenant needs their own branded experience
- Per-tenant data isolation in Grafana requires either separate workspaces (multiplying the per-user cost above) or folder/permission modeling within a shared workspace — added complexity with no corresponding benefit over the application-layer tenant isolation already built into the API layer (ADR-005)
- A second login/URL for end users (unless SSO/embedding is built) fragments the product experience relative to a native, Cognito-integrated React app

**Ecosystem coherence:** Adopting AMG introduces a new managed service, workspace IAM configuration, and billing dimension outside the existing FastAPI + Cognito + React stack, against the platform's stated coherence principle.

### Where Grafana would have won
Time-to-first-dashboard and built-in alerting UI are genuine Grafana strengths. These are better suited to an *internal* ops/monitoring view (e.g., cross-tenant device health for the platform operator) than the *customer-facing* product surface this decision covers. Not pursued at launch — no internal ops dashboard requirement has been raised.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| Amazon Managed Grafana | Per-user cost scales with customer growth; white-labeling requires Enterprise tier; adds a second auth surface |
| React app served via Fargate (SSR) | No SSR requirement identified (authenticated dashboard, no SEO need); Fargate + ALB cost (~$25–63/month) comparable to Grafana with no offsetting benefit over static hosting |

---

## Decision 2 — Retain CloudFront in front of S3 at launch

### Decision

Host the React build on **S3 + CloudFront**, including at launch, despite an initially geographically concentrated user base.

### Rationale

CloudFront's role in this architecture is not primarily latency optimization — it is the mechanism that provides **HTTPS and a custom domain** for a static site, which S3 alone cannot do:

- S3 static website hosting (`bucket.s3-website-region.amazonaws.com`) is HTTP-only — no TLS support
- S3 REST endpoint supports HTTPS but only on the AWS-owned domain, with no custom domain and no SPA path-fallback routing (required for React Router)
- The rest of the stack (Cognito auth, JWT-over-WebSocket to the ALB) is HTTPS-only; browsers block mixed content, so an HTTP-served frontend would break API/auth calls entirely

**Cost is not a meaningful factor either way:** S3 + CloudFront is estimated at ~$5/month at launch traffic, within CloudFront's free tier (1 TB data transfer/month, first 12 months). Dropping CloudFront would save an estimated $1–2/month while requiring an alternative HTTPS/custom-domain solution (e.g., ALB + ACM in front of S3) that would likely cost more than CloudFront itself.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| S3 static website hosting only (no CloudFront) | No HTTPS support — breaks mixed-content requirements with the rest of the HTTPS-only stack |
| S3 REST endpoint only (no CloudFront) | No custom domain; no SPA fallback routing for React Router |
| ALB + ACM in front of S3 (alternative to CloudFront) | More infrastructure and likely higher cost than CloudFront for the same HTTPS/custom-domain outcome |

---

## Consequences

### Positive
- No per-user cost exposure as the tenant/customer base grows
- Full control over branding and white-labeling per tenant
- Consistent with existing Cognito-based auth — single login experience for end users
- Lowest-cost hosting option evaluated (~$5/month), with headroom under CloudFront's free tier
- Frontend layer decision is now consistent with the AWS ecosystem coherence principle applied to every other layer

### Negative / trade-offs
- Higher upfront engineering effort than Grafana — dashboards, charts, and real-time WebSocket wiring must be built rather than configured
- No built-in alerting UI — alerting is already handled via the `alert_rules` table + Lambda/SNS/SES (ADR-004), so this is not a net-new gap, but it means no visual rule-builder UI without custom development
- Deferred: an internal Grafana-based ops dashboard remains a reasonable future addition for platform-operator use, separate from the customer-facing product

### Out of scope for this ADR
- Internal/ops-facing Grafana dashboard for cross-tenant device health monitoring (not requested; flagged as a possible future addition)
- Frontend state management, real-time update/reconnect strategy, and per-tenant theming implementation detail
- CI/CD pipeline and cache invalidation strategy for frontend deploys

---

## References

- IoT sensor platform — architecture decisions (2026-06-23)
- ADR-004 — Processing & storage layer (2026-07-18)
- ADR-005 — API layer (2026-07-19), referenced for Cognito/tenant isolation integration
- Frontend layer — React vs. Grafana, CloudFront decision — session note (2026-07-20)
- AWS Fargate pricing, us-east-1 (verified 2026)
- Amazon Managed Grafana pricing (verified against AWS documentation, 2026)
