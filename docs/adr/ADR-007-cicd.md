# ADR-007 — CI/CD layer: pipeline structure, triggers, rollback strategy

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-07-26 |
| **Deciders** | Yogo (product owner) |
| **Builds on** | ADR-001 — IoT platform architecture overview; ADR-002 — Edge layer; ADR-003 — Ingestion layer; ADR-004 — Processing & storage layer; ADR-005 — API layer; ADR-006 — Frontend layer |

---

## Context

All five architecture layers (edge, ingestion, processing/storage, API, frontend) were closed with formal ADRs, but CI/CD was only ever referenced directionally — the original architecture decisions doc (2026-06-23) called for "three independent GitHub Actions pipelines (edge agent, backend, frontend)" and the edge OTA flow was sketched in ADR-001/ADR-002 (GitHub Actions → ECR → Greengrass staged rollout). No dedicated design session had formalized repo structure, deploy triggers, environment promotion model, or rollback strategy across all four deploy targets (edge, Lambda, Fargate, frontend).

Four decisions needed to be made:

1. Repository structure for the pipelines
2. Whether Lambda and Fargate (both "backend") share one workflow or use two
3. Deploy triggers and environment promotion model per pipeline
4. Rollback strategy per deploy target

---

## Decision 1 — Separate repos per layer, no monorepo

### Decision

Edge, backend, and frontend each live in **separate repositories**, each with its own GitHub Actions workflow(s). No monorepo with path-based triggering.

### Rationale

- Each layer has an independent release cadence and a different risk profile — edge deploys touch physical devices in the field, backend/frontend deploy to cloud infrastructure on every merge. Coupling them in one repo adds path-filtering complexity for no shared benefit at this scale.
- Consistent with the platform's "simplicity over over-engineering" value — monorepo tooling (path filters, selective workflow triggers) is unnecessary complexity when the three codebases have no shared build step.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| Monorepo with path-based triggers | Adds tooling complexity (path filters, selective CI triggers) with no shared build/dependency benefit across edge (Python/Docker), backend (Python/Lambda/Fargate), and frontend (React) |

---

## Decision 2 — Four independent workflows (edge, Lambda, Fargate, frontend)

### Decision

Backend splits into **two independent workflows** — Lambda (ingestor + alerting) and Fargate (FastAPI) — rather than one combined backend workflow. Combined with edge and frontend, this gives **four workflows total**.

### Rationale

- Lambda and Fargate are different deploy targets with different build artifacts (zip/container image for Lambda vs. Docker image for Fargate), different deploy mechanisms, and different failure blast radius — a bad Fargate deploy affecting the API should not be coupled to an ingestor deploy in the same workflow run.
- Independent workflows allow each to fail, retry, and roll back without affecting the other.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| One combined backend workflow (Lambda + Fargate) | Couples two independent deploy targets; a failure or rollback need in one forces reasoning about both |

---

## Decision 3 — Deploy triggers and environment model

### Decision

| Pipeline | Trigger | Environment model |
|---|---|---|
| Edge | `workflow_dispatch` (manual only) | Prod-only |
| Backend (Lambda) | Push/merge to `main` (automatic) | Prod-only |
| Backend (Fargate) | Push/merge to `main` (automatic) | Prod-only |
| Frontend | Push/merge to `main` (automatic) | Prod-only |

No dev/staging tier at launch. No manual approval gates on backend or frontend deploys.

### Rationale

- **Edge is manual-only** because a merge-triggered deploy would push to physical devices in the field via Greengrass's staged rollout (10%/50%/100%) without an explicit human decision point. Cloud deploys (backend, frontend) don't carry this physical-device risk and can safely deploy on every merge.
- **Prod-only, fully automatic backend/frontend** is consistent with launch-scale simplicity (~10 devices, small tenant count) and the platform's recurring "simplicity over over-engineering" principle — a staging tier and approval gates add process overhead disproportionate to current risk and team size.
- No approval gate on backend/frontend accepts the trade-off that a bad merge to `main` deploys immediately; this is mitigated by the rollback strategy in Decision 4, not by adding a pre-deploy gate.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| dev → staging → prod promotion | Disproportionate process overhead at 10-device/small-tenant launch scale; no team or workload justification yet |
| Manual approval gate on backend/Fargate deploys | Adds friction to every merge; rollback-on-native-mechanism (Decision 4) is fast enough to substitute for a pre-deploy gate |
| Auto-trigger edge deploys on push | Fleet-wide device rollout should not happen without deliberate human trigger |

---

## Decision 4 — Rollback via native per-service mechanism only, no fallback layer

### Decision

Rollback relies exclusively on **each service's built-in "point to previous version" mechanism**. No CI re-run as a rollback path, and no additional rollback infrastructure (e.g., CodeDeploy blue/green) is introduced.

### Rollback mechanisms by service

| Service | Mechanism |
|---|---|
| Lambda (ingestor + alerting) | Versions + aliases — publish immutable versions on deploy; roll back by pointing the `prod` alias at the previous version |
| Fargate (FastAPI) | ECS task definition revisions — roll back by updating the service to the previous revision |
| Frontend (S3 + CloudFront) | S3 object versioning — restore the previous object version, then invalidate the CloudFront cache |
| Edge (Greengrass) | Staged rollout mechanism itself (10% / 50% / 100%) — rollback behavior is inherent to the staged deployment already defined for edge OTA (ADR-001/ADR-002); not re-specified here |

### Version retention policy

**Retain 1 prior version** for each native rollback target:

- Lambda: current + 1 previous published version retained (older versions may be pruned)
- Fargate: current + 1 previous task definition revision retained
- Frontend: current + 1 previous S3 object version retained

### Rationale

- Every deploy target already has a native, fast, no-rebuild rollback mechanism (Lambda alias repoint, ECS task definition repoint, S3 versioned restore) — introducing a parallel fallback path (e.g., re-running a prior CI workflow) duplicates this capability without adding safety, and adds a second rollback procedure to maintain and remember under pressure.
- Retaining exactly 1 prior version is the minimum needed for the native mechanism to function (rollback requires *a* previous version to exist) while avoiding unbounded version accumulation and its associated storage/management overhead — consistent with launch-scale simplicity.
- No CodeDeploy blue/green or automated health-check rollback: this is genuine additional infrastructure with no offsetting benefit at current traffic/risk levels; a manual repoint is fast enough at this scale.

### Alternatives considered

| Option | Reason rejected |
|---|---|
| CI re-run as rollback (redeploy last-good commit) | Slower (full pipeline re-run) than a native version/alias repoint; redundant given every service already has a native mechanism |
| Manual AWS CLI/console repoint as primary strategy | Bypasses CI/CD audit trail if used as the *primary* path; acceptable only as an ad hoc break-glass action, not the documented strategy |
| CodeDeploy blue/green (Fargate) | Adds infrastructure (traffic shifting, automated health-check rollback) disproportionate to current scale and risk |
| Retain N > 1 prior versions | No identified need beyond one-step-back rollback at current deploy frequency and team size; adds storage/management overhead without a corresponding benefit |

---

## Consequences

### Positive
- Four independently deployable, independently rollback-able pipelines — a bad deploy in one (e.g., Fargate) cannot block or complicate rollback in another (e.g., Lambda)
- Rollback is fast in all cases — no rebuild required, just a pointer/alias/revision change
- No new infrastructure introduced for CI/CD or rollback — consistent with the platform-wide simplicity principle applied at every other layer
- Manual edge trigger prevents accidental fleet-wide device rollouts on routine merges

### Negative / trade-offs
- No pre-deploy approval gate on backend/frontend means a bad merge to `main` reaches prod before it can be caught — mitigated, not eliminated, by fast native rollback
- Retaining only 1 prior version means rollback can only go back one step — a second consecutive bad deploy before the rollback is executed would leave no good version to revert to
- Four separate workflow files (one per deploy target) is more maintenance surface than a single combined workflow, though each is simpler in isolation
- No dev/staging tier means all testing must happen pre-merge (local, PR checks) — there is no cloud-hosted environment to catch integration issues before prod

### Out of scope for this ADR
- CI build steps, test stages, and secrets/IAM configuration per workflow
- Edge staged rollout mechanics (10%/50%/100%) — already covered under ADR-001/ADR-002
- Revisiting the prod-only environment model or approval gates (future trigger: team growth or increased deploy risk tolerance concerns)

---

## References

- IoT sensor platform — architecture decisions (2026-06-23)
- ADR-001 — IoT platform architecture overview (2026-06-23)
- ADR-002 — Edge layer: MQTT topic structure and SQLite offline buffer (2026-06-24)
- ADR-003 — Ingestion layer: drop Kinesis, MQTT QoS 1, ingestor deduplication (2026-06-24)
- ADR-004 — Processing & storage layer (2026-07-18)
- ADR-005 — API layer (2026-07-19)
- ADR-006 — Frontend layer: React + Recharts, S3 + CloudFront hosting (2026-07-20)
- Session note: CI/CD pipelines — repo structure, triggers, rollback strategy (2026-07-26)
