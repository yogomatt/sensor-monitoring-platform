# Design — IoT Sensor Monitoring Platform: Fleet Safety & DevOps

| Field | Value |
|---|---|
| **Spec type** | Feature Spec (Increment 3: Fleet Safety & DevOps) — Design phase |
| **Version** | 1.0 |
| **Date** | 2026-07-26 |
| **Derived from** | `requirements.md` Fleet Safety & DevOps v1.0 |
| **Depends on** | Increments 1 (MVP) and 2 (Enterprise) design.md and implementation complete |
| **Status** | Scope locked; builds on MVP and Enterprise architecture |

---

## 1. Architecture overview (Increment 3 scope)

Adds to MVP + Enterprise:
- **AWS IoT Greengrass** for staged edge agent OTA
- **Four independent CI/CD pipelines** (GitHub Actions workflows)
- **Comprehensive end-to-end test suite** (data loss, tenant isolation, failure paths)
- **Infrastructure-as-Code** with version control

```
[Git Repos: edge / backend / frontend]
           │        │         │
           ↓        ↓         ↓
[GitHub Actions Workflows]
  - edge: manual trigger → ECR push → Greengrass stage (10/50/100%)
  - Lambda: auto on merge → versioned function + alias
  - Fargate: auto on merge → new ECS task definition
  - frontend: auto on merge → S3 sync + CloudFront invalidate

[AWS IoT Greengrass]
  ├─ Stage 1: 10% of fleet
  ├─ Stage 2: 50% of fleet
  └─ Stage 3: 100% of fleet
     (Each stage requires manual approval)

[Test Infrastructure]
  ├─ End-to-end tests (network failure, tenant isolation, reimage)
  ├─ Load tests (500 readings/sec, 10 min)
  └─ Alerting performance tests (10k devices/sec)
```

Satisfies: R-FLEET-1, R-FLEET-2, R-FLEET-3, R-FLEET-4, R-ING-3, R-ING-4, R-CICD-1 – R-CICD-7, R-TEST-1 – R-TEST-7, R-NFR-2, R-NFR-3, R-NFR-4

---

## 2. Component design (Increment 3 additions)

### 2.1 AWS IoT Greengrass staged deployment
**Requirements addressed:** R-FLEET-1, R-FLEET-2, R-FLEET-3

AWS IoT Greengrass Core component distribution (v2):
- **Staged deployment configuration:**
  ```
  Stage 1: Minimum 10%, maximum 20% of fleet, wait 24h for metrics validation
  Stage 2: Minimum 40%, maximum 60% of fleet, wait 24h for metrics validation
  Stage 3: Minimum 90%, maximum 100% of fleet (full rollout)
  ```
- **Manual trigger:** `workflow_dispatch` on edge repo, operator selects target stage
- **Container component:** Pulls `edge-agent:v1.2.3` from ECR, configured via Greengrass local shadow
- **Rollback:** Operator pushes previous image tag; Greengrass re-deploys in reverse order (100% → 50% → 10%)

**Greengrass deployment flow:**
```json
{
  "deploymentName": "edge-agent-v1.2.3",
  "targetArn": "arn:aws:iot:...:thingGroup/all-devices",
  "components": {
    "EdgeAgentComponent": {
      "version": "1.2.3",
      "containerParams": {
        "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/edge-agent:v1.2.3",
        "volumeMounts": [...]
      }
    }
  },
  "deploymentPolicies": {
    "failureHandlingPolicy": "DO_NOTHING",
    "componentUpdatePolicy": {
      "timeoutInSeconds": 60
    },
    "configurationValidationPolicy": {
      "timeoutInSeconds": 60
    }
  }
}
```

**Greengrass canary metrics** (monitored during each stage):
- **Agent crash rate** (component restart count)
- **MQTT publish latency** (p99 time-to-publish)
- **Buffer depth** (SQLite row count; if growing, indicates publish failures)

If any metric exceeds threshold during a stage, operator stops rollout and triggers rollback.

**Design decision — manual trigger, not automatic:** Prevents accidental fleet-wide deployments from a botched test commit. Operator must explicitly approve each stage, viewing canary metrics before proceeding.

### 2.2 Four independent CI/CD pipelines
**Requirements addressed:** R-CICD-1, R-CICD-2, R-CICD-3, R-CICD-4, R-CICD-5

**Pipeline 1: Edge Agent (GitHub Actions workflow)**
- **Trigger:** `workflow_dispatch` (manual)
- **Steps:**
  1. Build Docker image from `edge-agent:main`
  2. Tag as `v{semver}` (operator-provided version or auto-increment)
  3. Push to ECR with `latest` and `v{semver}` tags
  4. Operator manually triggers Greengrass staged deployment in next step
- **Rollback:** Operator selects previous tag in workflow; re-deploy via Greengrass in reverse

**Pipeline 2: Lambda Ingestor & Alerting (shared backend repo)**
- **Trigger:** Auto on merge to `main`
- **Steps:**
  1. Run unit tests
  2. Build Lambda package (zip)
  3. Publish new Lambda function version
  4. Update `ingestor:live` alias to point to new version
  5. Update `alerting:live` alias to point to new version
- **Rollback:** Operator re-points aliases to previous published version (no re-build needed)
  ```bash
  aws lambda update-alias --function-name ingestor \
    --name live --function-version 42  # Previous version
  ```

**Pipeline 3: FastAPI Fargate (shared backend repo)**
- **Trigger:** Auto on merge to `main`
- **Steps:**
  1. Run unit tests
  2. Build Docker image, tag as `fargate:{git-sha}`
  3. Push to ECR
  4. Create new ECS task definition revision (pointing to new image)
  5. Update ECS service to use new task definition
- **Rollback:** Operator points service back to previous task definition revision
  ```bash
  aws ecs update-service --cluster prod --service api \
    --task-definition api:3  # Previous revision
  ```

**Pipeline 4: React Frontend**
- **Trigger:** Auto on merge to `main`
- **Steps:**
  1. Run unit tests + build checks
  2. Build React app (`npm run build`)
  3. Sync to S3 (with versioning enabled)
  4. Invalidate CloudFront distribution
- **Rollback:** Restore previous S3 object versions + new CloudFront invalidation
  ```bash
  # List previous versions
  aws s3api list-object-versions --bucket frontend --prefix index.html
  # Copy previous version to current
  aws s3api copy-object --bucket frontend --copy-source frontend/index.html?versionId=ABC123 ...
  aws cloudfront create-invalidation --distribution-id E123 --paths '/*'
  ```

**Key design decision — shared backend repo, separate pipelines:**
- Ingestor/Alerting and Fargate share the same GitHub repo but trigger independent pipelines
- A failure in one Lambda does not block Fargate rollback; a bad API change does not block Lambda rollback
- Operators can confidently roll back one service without affecting others

**Retention policy:**
- Edge: Keep 5 most recent ECR tags
- Lambda: Keep 5 most recent published versions per function
- Fargate: Keep 5 most recent task definition revisions
- Frontend: S3 versioning enabled (infinite, but CloudFront serves `latest` by default)

### 2.3 Infrastructure-as-Code
**Requirements addressed:** R-CICD-6, R-CICD-7

CDK project (TypeScript) in a separate repo, version-controlled:

**CDK stacks:**
1. **Networking stack:** VPC, subnets, security groups, ALB
2. **Database stack:** RDS PostgreSQL with TimescaleDB, subnet groups
3. **Compute stack:** ECS cluster, Fargate service, IAM roles, task definitions
4. **Storage stack:** S3 buckets (frontend, raw archive), CloudFront distribution
5. **Auth stack:** Cognito User Pool, app client, domain
6. **IoT stack:** IoT Core endpoint, rules, X.509 certificates, Greengrass core provisioning
7. **Lambda stack:** Ingestor and Alerting Lambda functions, IAM policies, log groups

**Deployment procedure:**
```bash
# Deploy to test environment first
cdk deploy --context env=test

# Verify test deployment
npm run e2e-tests

# Deploy to prod
cdk deploy --context env=prod --require-approval never
```

**Design decision — separate IaC repo, not monorepo:**
- Infrastructure changes reviewed separately from application code
- Infrastructure version aligns with deployment version (tagged releases)
- Operators can reproduce any prior infrastructure state independently

### 2.4 End-to-end test suite
**Requirements addressed:** R-TEST-1 – R-TEST-7

**Test harness (Python, pytest framework):**

```python
# T-1: Network failure and replay order
@pytest.mark.e2e
async def test_network_severing_and_replay():
    """Verify zero data loss and correct replay order on reconnect."""
    # 1. Edge agent starts; publishes 10 readings (1 per sec)
    # 2. Kill MQTT connectivity mid-cycle (after 5 readings)
    # 3. Edge continues buffering for 30 sec (15 more readings queued)
    # 4. Restore connectivity
    # 5. Verify all 25 readings in TimescaleDB in chronological order
    # 6. Verify zero duplicates (upsert constraint)

# T-2: Tenant isolation
@pytest.mark.e2e
async def test_tenant_isolation():
    """Verify tenant A cannot retrieve tenant B data."""
    # 1. Log in as tenant-a user
    # 2. Query /api/v1/readings (should see only tenant-a data)
    # 3. Attempt to access tenant-b device ID (should get 403)
    # 4. Attempt to access tenant-b via WebSocket (should get auth error)
    # 5. Query database directly (outside API) to verify tenant isolation is real

# T-3: Ingestor Lambda failure
@pytest.mark.e2e
async def test_ingestor_lambda_failure_doesnt_block_s3():
    """Verify S3 raw archive still receives data if ingestor fails."""
    # 1. Deploy ingestor Lambda that fails after 100 invocations
    # 2. Send 150 readings
    # 3. Verify first 100 in TimescaleDB, next 50 in S3 only (not in DB)

# T-4: Device reimage (sequence_no reset)
@pytest.mark.e2e
async def test_device_reimage_no_duplicate_keys():
    """Verify sequence_no reset doesn't corrupt dedup constraint."""
    # 1. Device publishes readings with seq 1–20
    # 2. Simulate reimage (reset seq to 0)
    # 3. Device publishes readings with seq 0–10
    # 4. Verify all 30 readings in database
    # 5. Verify no dedup violations (unique constraint on device, seq, time)

# T-5: Load test (500 readings/sec)
@pytest.mark.load
async def test_high_throughput_500_readings_sec():
    """Generate 500 readings/sec for 10 min; validate zero loss and latency."""
    # 1. Configure 50 simulated devices
    # 2. Each device publishes 10 readings/sec
    # 3. Monitor RDS CPU, Lambda duration, S3 write latency
    # 4. After 10 min, query database
    # 5. Verify: 300,000 readings total, all present, no duplicates

# T-6: Alerting performance (10k devices/sec)
@pytest.mark.performance
async def test_alerting_throughput_10k_devices_sec():
    """Evaluate 10,000 device alert rules per sec; validate <100ms p99."""
    # 1. Create 10k alert rules (all active, threshold-based)
    # 2. Simulate inbound readings at 1000 readings/sec
    # 3. Measure Alerting Lambda invocation duration
    # 4. Assert p99 < 100ms

# T-7: Rollback procedures
@pytest.mark.manual
async def test_rollback_procedures_work():
    """Verify Lambda alias repoint, ECS task-def repoint, S3 version restore."""
    # 1. Current Lambda version: 10; test points alias to version 9
    # 2. Verify function still invokes (via alias)
    # 3. Current ECS task-def: rev 5; test points service to rev 4
    # 4. Verify service update succeeds
    # 5. Current S3 object: v123; list previous version v122
    # 6. Restore v122; verify CloudFront invalidates
```

**Test environment:**
- Separate AWS account (or isolated VPC in same account)
- Fixture-based provisioning (spin up test environment, run tests, tear down)
- CI integration: tests run on every PR (not pushed to main unless tests pass)

**Design decision — live end-to-end tests, not mocks:**
- Tests interact with actual RDS, S3, Lambda, Cognito
- Validates not just code logic but AWS API integration
- Cost: ~$50/month for test environment (acceptable)
- Benefit: catches integration bugs that unit tests miss

### 2.5 Documented rollback runbooks
**Requirements addressed:** R-CICD-4, R-CICD-7

**Runbook 1: Edge Agent Rollback**
```markdown
## Edge Agent Rollback Procedure

### Trigger conditions:
- High crash rate on devices (> 5% of fleet)
- MQTT publish latency p99 > 5s
- Buffer depth growing uncontrollably

### Steps:
1. Log into AWS Console → IoT Greengrass Deployments
2. Identify current deployment (e.g., `edge-agent-v1.2.3`)
3. Create new deployment with previous version tag (e.g., `edge-agent-v1.2.2`)
4. Set deployment policy: 100% of fleet (full rollback)
5. Deploy (no staged rollout for rollback)
6. Monitor device heartbeats for 10 min
7. If metrics improve, mark complete
8. If metrics still poor, escalate to oncall engineer

### Verification:
- CloudWatch metrics: CrashCount < 1%, PublishLatencyP99 < 2s
- Device heartbeats appearing in dashboard
- No error spike in logs
```

**Runbook 2: Lambda Rollback**
```markdown
## Lambda Rollback Procedure

### Trigger conditions:
- Ingestor Lambda error rate > 1%
- Alerting Lambda duration p99 > 10s
- S3 raw archive writes failing

### Steps:
1. Identify current `ingestor:live` alias version
   ```
   aws lambda get-alias --function-name ingestor --name live
   # Output: FunctionVersion: 42
   ```
2. Get previous published version (e.g., 41)
   ```
   aws lambda list-versions-by-function --function-name ingestor | grep -A5 "Version.*41"
   ```
3. Repoint alias to previous version
   ```
   aws lambda update-alias --function-name ingestor --name live \
     --function-version 41
   ```
4. Verify alias repoint
   ```
   aws lambda get-alias --function-name ingestor --name live
   # Confirm FunctionVersion: 41
   ```
5. Monitor CloudWatch error metric for 10 min
6. If resolved, document incident
7. If not resolved, escalate

### Verification:
- `aws logs tail /aws/lambda/ingestor --follow` shows no errors
- TimescaleDB insert count remains stable
- S3 raw archive object count increasing
```

**Runbook 3: Fargate Rollback**
```markdown
## FastAPI Fargate Rollback Procedure

### Trigger conditions:
- API error rate > 5%
- Request latency p99 > 10s
- 403 Forbidden spike (auth issue)

### Steps:
1. Identify current ECS task definition
   ```
   aws ecs describe-services --cluster prod --services api \
     | grep taskDefinition
   # Output: api:5
   ```
2. List previous task definition revisions
   ```
   aws ecs list-task-definition-revisions --family-prefix api
   # Find revision 4
   ```
3. Repoint service to previous task definition
   ```
   aws ecs update-service --cluster prod --service api \
     --task-definition api:4
   ```
4. Monitor Fargate logs for 10 min
   ```
   aws logs tail /ecs/api --follow
   ```
5. If resolved, document incident
6. If not resolved, escalate

### Verification:
- New task definition revision created and is running
- Old tasks terminated gracefully (connection draining)
- ALB health checks green
```

**Runbook 4: Frontend Rollback**
```markdown
## Frontend Rollback Procedure

### Trigger conditions:
- 5xx errors on dashboard (React app crash)
- Authentication flow broken
- Data not loading (API integration issue)

### Steps:
1. List previous S3 object versions
   ```
   aws s3api list-object-versions --bucket frontend \
     --prefix index.html
   # Output: versionId=ABC123 (current), versionId=XYZ789 (previous)
   ```
2. Copy previous version to current
   ```
   aws s3api copy-object \
     --bucket frontend \
     --copy-source frontend/index.html?versionId=XYZ789 \
     --key index.html
   ```
3. Invalidate CloudFront cache
   ```
   aws cloudfront create-invalidation \
     --distribution-id E1A2B3C4D5E6F7 \
     --paths '/*'
   ```
4. Open dashboard in incognito window
   ```
   # Verify: dashboard loads, can log in, can see data
   ```
5. Monitor CloudFront access logs for errors
   ```
   aws logs tail /cloudfront/distribution --follow
   ```
6. If resolved, document incident
7. If not resolved, escalate

### Verification:
- CloudFront cache hit rate > 90% (after invalidation)
- No 4xx or 5xx in access logs
- Browser console has no JavaScript errors
```

---

## 3. Data flow (Increment 3 unchanged from Increment 2)

Increment 3 adds operational controls (CI/CD, testing, rollback) but does not change the core data flow. Data path remains:
```
1. Edge → MQTT → IoT Core
2. IoT Core → Rules Engine → Lambda ingestor, S3 raw, Alerting Lambda
3. FastAPI → TimescaleDB + cache
4. Dashboard → WebSocket/REST
```

---

## 4. Design decisions specific to Increment 3

**Decision 1: Four independent pipelines (not monorepo)**
- Justification: Operational independence. A broken Lambda build never blocks frontend deployment. Clear ownership. Easier rollback.

**Decision 2: Manual trigger for edge OTA**
- Justification: Fleet-wide deploy is high-risk; manual approval prevents accidental full rollout from a test commit.

**Decision 3: Staged Greengrass rollout (10/50/100%)**
- Justification: Canary pattern reduces blast radius. Operators can stop rollout at 10% if metrics degrade.

**Decision 4: Retain only 1 prior version (not 5)**
- Justification: Cost optimization for launch scale. Prior version is minimum needed for rollback. If older rollback needed, redeploy from source and tag explicitly.

**Decision 5: Live end-to-end tests, not mocks**
- Justification: Integration bugs (AWS API, permissions, configuration) only caught via real infrastructure. Mocks pass when deployment fails.

---

## 5. Upgrade triggers (future planning)

As stipulated in R-NFR-2, new infrastructure components require documented upgrade triggers:

| Component | Current | Upgrade trigger |
|---|---|---|
| RDS instance size | db.t4g.micro | CPU sustained > 80% for 24h, or query latency p99 > 1s |
| Fargate task count | 1 | ALB response time p99 > 2s or error rate > 1% |
| Fargate CPU/memory | 0.5 CPU / 1 GB | Fargate task kills due to OOM or CPU throttling |
| Lambda concurrency | Unlimited | Reserved concurrency needed; throttle errors observed |
| S3 transfer acceleration | Off | Latency from distant regions becomes issue |
| RDS read replicas | None | Query load on primary > 50% CPU for sustained period |

---

## 6. Next steps

- [ ] Review and accept design
- [ ] Proceed to tasks.md for wave-based implementation plan
- [ ] Increments 1 (MVP) and 2 (Enterprise) must be complete before starting Increment 3

</content>
