# IoT Sensor Monitoring Platform — AI Agent Guide

## What This Project Is

A multi-tenant IoT platform that collects sensor readings from Raspberry Pi edge devices and displays them on real-time dashboards. The system guarantees zero data loss during network outages using a write-ahead SQLite buffer pattern.

**Key flow:** Edge devices → AWS IoT Core (MQTT) → Lambda → PostgreSQL → FastAPI → React Dashboard

## Your Role as an AI Agent

You're working on a structured, multi-increment project where **all architectural decisions have already been made**. Your job is to implement tasks according to existing specifications, not redesign the system.

## Critical Rules

### 1. Follow the Specs Exactly
- **Don't suggest alternatives** to technologies already chosen (e.g., "Why not use Kafka instead of IoT Core?")
- **Don't add features** not listed in requirements.md

### 2. Update Task Status
When you complete a task:
1. Change status from `pending` → `done` in the owning project's `specs/tasks.md`
2. Update the Progress summary table
3. Check if dependent tasks are now unblocked

### 3. Trace Everything
- Every code change should trace to a task ID
- Every task should trace to a requirement ID
- Every requirement should trace to an ADR (Architecture Decision Record)

If you can't trace something, **ask before implementing**.

### 4. Maintain clean source code
- Keep component documentation with the component it describes.
- Keep shared documentation in `docs/`; keep increment specs in their project directory.
- Original consolidated specs in `docs/archive/original-spec/` are historical reference material.

## Project Structure Quick Reference

```
iot-sensor-mvp/              # ← Start here (Increment 1)
├── specs/                   # Increment requirements, design, and task specs
└── edge-agent/              # Implementation starts here
    └── src/storage/         # SQLite schema (T-1.1 done)

iot-sensor-enterprise/       # Increment 2 (don't start yet)
iot-sensor-fleet-devops/     # Increment 3 (don't start yet)

docs/adr/ADR-*.md            # Shared architecture decisions (read-only)
```

## Current Status

Storage follows [ADR-008](docs/adr/ADR-008-native-postgresql-storage.md), which supersedes ADR-004: native PostgreSQL partitioning, manual purge preserving at least 30 days, no compression or rollups in the final product. Automatic purging requires a future approved spec.

- Refer to [MVP tasks](iot-sensor-mvp/specs/tasks.md).

## Key Technologies

| Layer | Technology | Why |
|-------|------------|-----|
| Edge | Python + SQLite WAL | Write-ahead pattern for crash safety |
| MQTT | AWS IoT Core | AWS-native, no separate broker needed |
| Ingestion | Lambda | Serverless, auto-scaling |
| Storage | PostgreSQL on RDS | Native time partitions, manual purge (ADR-008) |
| API | FastAPI on Fargate | Async Python, WebSocket support |
| Frontend | React + CloudFront | SPA with CDN distribution |
| Auth | Cognito | AWS-native JWT provider |

## Common Mistakes to Avoid

**Don't:** Create standalone task reports or completion reports (such as `TASK-*-COMPLETION.md`).  
**Do:** Record completion in the owning project's `specs/tasks.md` and Progress summary table.

**Don't:** Create `README.md` files in every subdirectory of a component
**Do:** Create one README for each component or when explicitly requested.

**Don't:** Create comprehensive tests during MVP  
**Do:** Wait for Increment 3 (Fleet DevOps) unless task explicitly requires testing

**Don't:** Leave one-off verification scripts in the codebase after they have served their purpose (for example, `verify_schema.py`).  
**Do:** Create temporary verification scripts when useful, run them, and remove them when verification is complete. Keep unit, integration, end-to-end, and other planned test suites that provide ongoing system coverage.

## When You're Unsure

**If the spec is unclear:** Ask the user before implementing  
**If you find a conflict:** Point it out and ask for clarification  
**If a task seems incomplete:** Check the ADR and design.md first

## Quick Commands Reference

```bash
# Edge Agent (Python)
docker build -t edge-agent:latest .
pytest tests/

# Backend (FastAPI)
pip install -r requirements.txt
uvicorn main:app --reload
pytest tests/ -v

# Frontend (React)
npm install
npm run build  # NOT npm run dev (no dev servers in prod)
aws s3 sync build/ s3://<bucket>/

# Database (PostgreSQL)
psql -h <rds-endpoint> -U postgres -d iot_platform
SELECT * FROM pg_partition_tree('sensor_readings');
```

## Success Metrics

Your work is successful when:
- All requirement IDs are satisfied
- Task status is updated to `done`
- Code follows conventions in `.kiro/steering/structure.md`

## Need More Context?

- **Product vision:** Read `.kiro/steering/product.md`
- **Technology stack:** Read `.kiro/steering/tech.md`
- **Project structure:** Read `.kiro/steering/structure.md`
- **Increment roadmap:** Read `docs/INCREMENTS.md`
- **Architecture decisions:** Read `docs/adr/ADR-*.md` files

---

**Remember:** You're implementing a well-specified system, not designing one. When in doubt, follow the spec.

<!-- BEGIN AWS Agent Toolkit rules -->
# AWS Guidance

- Where these AWS rules conflict with the project's own instructions, the
  project's instructions take precedence.
- Prefer the AWS MCP Server for AWS interactions — it provides sandboxed
  execution, observability, and audit logging. If unavailable, use the
  AWS CLI directly.
- Before starting a task, check whether a relevant AWS skill is available.
  Load the skill with `retrieve_skill` and prefer its guidance over
  general knowledge.
- When uncertain about specific AWS details (API parameters, permissions,
  limits, error codes), verify against documentation rather than guessing.
  State uncertainty explicitly if you cannot confirm.
- When creating infrastructure, prefer infrastructure-as-code (AWS CDK or
  CloudFormation) over direct CLI commands.
- When working with infrastructure, follow AWS Well-Architected Framework
  principles.
- Do not use em dashes in AWS resource names or descriptions. Use
  hyphens instead.

## Secret Safety

- MUST load the `aws-secrets-manager` skill first for any secret,
  credential, API key, token, or password task. MUST NOT call
  `secretsmanager get-secret-value` or `batch-get-secret-value`, and MUST
  NOT hit the Secrets Manager Agent daemon directly. MUST use
  `{{resolve:secretsmanager:secret-id:SecretString:json-key}}` with
  `asm-exec` so the secret resolves at runtime without entering context.
<!-- END AWS Agent Toolkit rules -->
