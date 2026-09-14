# Tasks — IoT Sensor Monitoring Platform: Fleet Safety & DevOps

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 3: Fleet Safety & DevOps) — Implementation phase |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Derived from** | `design.md` Fleet Safety & DevOps v1.0 |
| **Depends on** | All MVP (Increment 1) and Enterprise (Increment 2) tasks completed and passing |
| **Status** | Not started — all tasks pending |

---

## How to read this document

Each task lists its **Requirement(s)**, **Depends on** (task IDs that must complete first), and **Status**. Increments 1 and 2 completion is a prerequisite. Tasks in this phase focus on operational excellence: deployment pipelines, fleet safety, and comprehensive testing.

---

## Wave 1 — Infrastructure-as-Code and Greengrass setup

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-I3-1.1 | Create CDK project in separate repo; scaffold stacks (networking, database, compute, storage, auth, IoT, Lambda) | R-CICD-6 | — | pending |
| T-I3-1.2 | Implement CDK networking stack: VPC, subnets, security groups, ALB; deploy to test environment | R-CICD-6 | T-I3-1.1 | pending |
| T-I3-1.3 | Implement CDK database stack (RDS PostgreSQL + TimescaleDB); deploy to test environment | R-CICD-6 | T-I3-1.1 | pending |
| T-I3-1.4 | Implement CDK compute stack (ECS cluster, Fargate service, IAM roles); deploy to test environment | R-CICD-6 | T-I3-1.1 | pending |
| T-I3-1.5 | Implement CDK storage stack (S3 frontend, raw archive, CloudFront); deploy to test environment | R-CICD-6 | T-I3-1.1 | pending |
| T-I3-1.6 | Implement CDK auth stack (Cognito User Pool); deploy to test environment | R-CICD-6 | T-I3-1.1 | pending |
| T-I3-1.7 | Implement CDK IoT stack (IoT Core endpoint, rules, Greengrass provisioning); deploy to test environment | R-CICD-6 | T-I3-1.1 | pending |
| T-I3-1.8 | Implement CDK Lambda stack (ingestor, alerting functions, IAM policies, log groups); deploy to test environment | R-CICD-6 | T-I3-1.1 | pending |
| T-I3-1.9 | Provision AWS IoT Greengrass core on test device; configure staged deployment component (10/50/100% thresholds) | R-FLEET-2 | T-I3-1.7 | pending |
| T-I3-1.10 | Validate test deployment: tear down and redeploy via CDK; verify all services come up healthy | R-CICD-6 | T-I3-1.2 through T-I3-1.8 | pending |

---

## Wave 2 — CI/CD pipelines and versioning

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-I3-2.1 | Create GitHub Actions workflow for edge agent: build Docker image, tag, push to ECR; manual Greengrass trigger | R-FLEET-1, R-FLEET-3, R-CICD-1, R-CICD-3 | Increment 1 & 2 complete | pending |
| T-I3-2.2 | Create GitHub Actions workflow for Lambda: auto-deploy on merge, publish version, update aliases (ingestor:live, alerting:live) | R-CICD-1, R-CICD-2, R-CICD-4, R-CICD-5 | Increment 1 & 2 complete | pending |
| T-I3-2.3 | Create GitHub Actions workflow for Fargate: auto-deploy on merge, new ECS task definition, update service | R-CICD-1, R-CICD-2, R-CICD-4, R-CICD-5 | Increment 1 & 2 complete | pending |
| T-I3-2.4 | Create GitHub Actions workflow for frontend: auto-deploy on merge, S3 sync, CloudFront invalidation | R-CICD-1, R-CICD-2, R-CICD-4, R-CICD-5 | Increment 1 & 2 complete | pending |
| T-I3-2.5 | Implement retention policies: keep 5 ECR tags, 5 Lambda versions, 5 ECS task definitions, S3 versioning enabled | R-CICD-5 | T-I3-2.1, T-I3-2.2, T-I3-2.3, T-I3-2.4 | pending |
| T-I3-2.6 | Document version lifecycle and rollback procedure for each service (runbooks) | R-CICD-4, R-CICD-7 | T-I3-2.1 through T-I3-2.5 | pending |

---

## Wave 3 — End-to-end test suite

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-I3-3.1 | Scaffold test harness (pytest + custom fixtures) with test environment provisioning/teardown | R-TEST-1 through R-TEST-7 | T-I3-1.10 | pending |
| T-I3-3.2 | Implement test: network severing and replay order (verify zero data loss on reconnect) | R-TEST-1, R-EDGE-2, R-EDGE-3 | T-I3-3.1 | pending |
| T-I3-3.3 | Implement test: tenant isolation (attempt cross-tenant data access via REST, WebSocket, database query) | R-TEST-2, R-TEN-2, R-TEN-3 | T-I3-3.1 | pending |
| T-I3-3.4 | Implement test: ingestor Lambda failure does not block S3 raw archive writes | R-TEST-3, R-ING-3, R-ING-4 | T-I3-3.1 | pending |
| T-I3-3.5 | Implement test: device reimage (sequence_no reset) does not violate dedup constraint | R-TEST-4, R-FLEET-4, R-EDGE-7 | T-I3-3.1 | pending |
| T-I3-3.6 | Implement load test: 500 readings/sec for 10 min; monitor zero loss, query latency p99 < 1s | R-TEST-5, R-NFR-4 | T-I3-3.1 | pending |
| T-I3-3.7 | Implement alerting performance test: evaluate 10k device alert rules/sec; validate p99 < 100ms | R-TEST-6, R-ALERT-2 | T-I3-3.1 | pending |
| T-I3-3.8 | Implement rollback procedure validation: Lambda alias repoint, ECS task-def repoint, S3 version restore each work independently | R-TEST-7, R-CICD-4 | T-I3-3.1, T-I3-2.2, T-I3-2.3 | pending |
| T-I3-3.9 | Integrate test suite into CI: run on every PR, block merge if tests fail | — | T-I3-3.1 through T-I3-3.8 | pending |

---

## Wave 4 — Fleet safety (Greengrass OTA)

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-I3-4.1 | Build and push edge agent Docker image v1.0.0 to ECR | R-FLEET-1 | Increment 1 & 2 complete | pending |
| T-I3-4.2 | Configure Greengrass staged deployment policy: 10% → 50% → 100% with 24h stage duration | R-FLEET-2 | T-I3-1.9 | pending |
| T-I3-4.3 | Implement canary monitoring: dashboard tracking CrashCount, PublishLatencyP99, BufferDepth per stage | R-FLEET-2 | T-I3-4.2 | pending |
| T-I3-4.4 | Document Greengrass deployment trigger and canary metrics thresholds for stage promotion | R-FLEET-2, R-FLEET-3 | T-I3-4.3 | pending |
| T-I3-4.5 | Dry-run: trigger edge agent v1.0.0 deployment to 10% of test fleet; monitor 24h; verify canary metrics; document results | R-FLEET-2, R-FLEET-3, R-CICD-3 | T-I3-4.4 | pending |
| T-I3-4.6 | Dry-run rollback: operator reverts v1.0.0 to previous version; verify Greengrass deploys to 100% of fleet in rollback mode | R-FLEET-2, R-CICD-4 | T-I3-4.5 | pending |

---

## Wave 5 — Operational runbooks and documentation

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-I3-5.1 | Document edge agent rollback procedure (trigger conditions, AWS CLI steps, verification checklist) | R-CICD-4, R-CICD-7 | T-I3-2.1, T-I3-4.6 | pending |
| T-I3-5.2 | Document Lambda rollback procedure (alias repoint, verification, metrics) | R-CICD-4, R-CICD-7 | T-I3-2.2 | pending |
| T-I3-5.3 | Document Fargate rollback procedure (task definition repoint, ECS service update, verification) | R-CICD-4, R-CICD-7 | T-I3-2.3 | pending |
| T-I3-5.4 | Document frontend rollback procedure (S3 version restore, CloudFront invalidation, verification) | R-CICD-4, R-CICD-7 | T-I3-2.4 | pending |
| T-I3-5.5 | Document infrastructure deployment via CDK (prerequisites, command sequence, validation steps) | R-CICD-6 | T-I3-1.10 | pending |
| T-I3-5.6 | Document upgrade triggers for future scaling (RDS upsizing, Fargate scaling, Lambda concurrency) | R-NFR-2 | All prior tasks | pending |
| T-I3-5.7 | Create incident response guide (how to use runbooks, escalation procedures, post-incident review template) | R-CICD-7 | T-I3-5.1 through T-I3-5.4 | pending |

---

## Wave 6 — Final integration and smoke tests

| ID | Task | Requirement(s) | Depends on | Status |
|---|---|---|---|---|
| T-I3-6.1 | Run full end-to-end test suite (all 8 tests from Wave 3) in test environment; fix any failures | R-TEST-1 through R-TEST-7 | T-I3-3.9 | pending |
| T-I3-6.2 | Perform disaster recovery drill: destroy prod infrastructure via CDK, redeploy from scratch, verify operational parity | R-CICD-6 | T-I3-1.10 | pending |
| T-I3-6.3 | Verify all four pipelines work end-to-end: commit test change in each repo, observe auto-deployment (or manual trigger for edge) | R-CICD-1, R-CICD-2, R-CICD-3 | T-I3-2.1 through T-I3-2.4 | pending |
| T-I3-6.4 | Smoke test: log into dashboard, add device, generate readings, view in dashboard, verify WS live updates work | — | Increment 1 & 2 complete, T-I3-6.1 | pending |
| T-I3-6.5 | Performance validation: confirm p99 latencies and throughput meet targets documented in design.md § 2.4 | R-NFR-4, R-TEST-5, R-TEST-6 | T-I3-6.1 | pending |

---

## Explicitly deferred (do not schedule without a new spec)

- Multi-AZ RDS failover — indefinite (cost and complexity trade-off; revisit if SLA requires 99.99%)
- PostgreSQL row-level security (RLS) — indefinite (application-layer isolation sufficient)
- Redis-backed distributed rate limiting — indefinite (slowapi in-memory sufficient at launch)
- Internal ops dashboard (Grafana or otherwise) — indefinite (separate product; not SaaS customer-facing)
- dev/staging CI/CD environment tier — indefinite (manual feature branches sufficient for testing)

---

## Progress summary

| Wave | Total tasks | Done | In progress | Pending |
|---|---|---|---|---|
| 1 | 10 | 0 | 0 | 10 |
| 2 | 6 | 0 | 0 | 6 |
| 3 | 9 | 0 | 0 | 9 |
| 4 | 6 | 0 | 0 | 6 |
| 5 | 7 | 0 | 0 | 7 |
| 6 | 5 | 0 | 0 | 5 |
| **Total** | **43** | **0** | **0** | **43** |

---

## Next steps

- [ ] Ensure all MVP (Increment 1) and Enterprise (Increment 2) tasks are complete and stable
- [ ] Assign owners to Wave 1 tasks (infrastructure-as-code is prerequisite for all other waves)
- [ ] Assign owners to subsequent waves (blocked on prior wave completion)
- [ ] Update task status as work proceeds; maintain this file as source of truth for progress tracking

</content>
