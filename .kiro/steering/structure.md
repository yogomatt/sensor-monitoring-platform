# Project Structure

## Repository Organization

This workspace contains multiple increment-scoped specifications, each with its own requirements, design, and task breakdown.

```
sensor-monitoring-platform/
├── README.md                 # Workspace entry point
├── AGENTS.md                 # Workspace agent instructions
├── .kiro/steering/            # Product, technology, and structure guidance
├── docs/
│   ├── README.md             # Shared documentation index
│   ├── INCREMENTS.md         # Cross-increment roadmap
│   ├── adr/                  # Shared accepted ADRs (contents preserved)
│   └── archive/              # Historical delivery summary and original specs
├── iot-sensor-mvp/
│   ├── README.md             # Project entry point
│   ├── specs/
│   │   ├── requirements.md
│   │   ├── design.md
│   │   └── tasks.md          # Authoritative MVP progress
│   └── edge-agent/
│       ├── README.md
│       └── src/storage/      # Schema script
├── iot-sensor-enterprise/    # README + specs/{requirements,design,tasks}.md
└── iot-sensor-fleet-devops/  # README + specs/{requirements,design,tasks}.md
```

## Increment Dependencies

```
MVP (Increment 1)
└── Enterprise (Increment 2)
    └── Fleet DevOps (Increment 3)
```

Each increment must be complete and stable before starting the next.

## Architecture Decision Records (ADRs)

All architectural decisions are captured in ADR documents in `docs/adr/`:

- **ADR-001**: Platform architecture overview (referenced, but file missing from this workspace)
- **ADR-002**: Edge layer — MQTT topics, SQLite buffer, write-ahead pattern
- **ADR-003**: Ingestion layer — drop Kinesis, MQTT QoS 1, deduplication strategy
- **ADR-004**: Processing & storage — RDS vs Tiger Cloud, schema, alerting store, S3 naming
- **ADR-005**: API layer — FastAPI, Cognito, tenant scoping, WebSocket auth
- **ADR-006**: Frontend — React vs Managed Grafana, CloudFront rationale
- **ADR-007**: CI/CD — independent pipelines, rollback mechanisms, staged OTA

## EARS Requirements Format

All requirements follow the EARS (Easy Approach to Requirements Syntax) pattern:

```
WHEN [condition/event] THE SYSTEM SHALL [expected behavior]
```

Or for invariants:
```
THE SYSTEM SHALL [always-true behavior]
```

Each requirement is tagged with:
- **ID**: `R-{area}-{n}` (e.g., `R-EDGE-1`, `R-TEN-2`)
- **Source ADR**: Traceability to architectural decision

## Task Structure

Tasks are organized in waves to maximize parallelism:

- **Wave 1**: No dependencies (can start immediately in parallel)
- **Wave N**: Depends only on Wave N-1 completion
- **Status values**: `pending` / `in-progress` / `done` / `blocked`

Each task specifies:
- Requirement(s) addressed
- Dependencies (other task IDs)
- Current status

## Code Organization Patterns

### Edge Agent (Python)
```
edge-agent/
├── src/
│   ├── storage/           # SQLite schema and DAL
│   ├── mqtt/              # MQTT client wrapper
│   ├── sensors/           # Sensor reading interfaces
│   └── main.py            # Polling loop entrypoint
├── tests/
├── Dockerfile
└── requirements.txt
```

### Backend (FastAPI)
```
backend/
├── app/
│   ├── api/
│   │   ├── dependencies/  # JWT validation, tenant scoping
│   │   ├── endpoints/     # REST routes by domain
│   │   └── websocket.py   # WebSocket handler
│   ├── models/            # Pydantic schemas
│   ├── db/                # Database connection and queries
│   └── main.py            # FastAPI app entrypoint
├── tests/
└── requirements.txt
```

### Frontend (React)
```
frontend/
├── src/
│   ├── components/        # Reusable UI components
│   ├── pages/             # Route-level pages
│   ├── services/          # API clients, WebSocket
│   ├── auth/              # Cognito integration
│   └── App.jsx            # Router config
├── public/
└── package.json
```

### Lambda Functions
```
lambda/
├── ingestor/              # Ingest sensor readings
│   ├── handler.py
│   └── requirements.txt
└── alerting/              # Evaluate alert rules (Increment 2)
    ├── handler.py
    └── requirements.txt
```

## Multi-Tenant Data Flow

Every data object is tagged with `tenant_id` from creation through query:

1. **Edge**: Device cert → MQTT topic includes `{tenant_id}` at level 2
2. **Ingestion**: Lambda extracts `tenant_id` from payload
3. **Storage**: All tables include `tenant_id` column, indexed
4. **API**: JWT claim `custom:tenant_id` → FastAPI dependency injects into `WHERE` clause
5. **Frontend**: Dashboard queries scoped automatically via bearer token

## Key Conventions

### Naming
- **Tables**: Lowercase with underscores (`sensor_readings`, `device_heartbeats`)
- **Indexes**: Descriptive prefix (`idx_pending`, `idx_tenant_device`)
- **MQTT topics**: `iot/{tenant_id}/{device_id}/{category}/{type}`
- **S3 paths**: Hive-style `raw/{tenant_id}/year=/month=/day=/hour=/{device_id}_{timestamp}_{sequence_no}.json`

### Data Patterns
- **Write-ahead**: Always persist locally before publishing (edge) or processing (Lambda)
- **Idempotency**: Unique constraints enable safe replay (`device_id, sequence_no, time`)
- **Timestamps**: ISO 8601 UTC everywhere, use device reading time (not ingestion time)
- **Sequence numbers**: Per-device monotonic counter, resets on reimage (tolerated by design)

### Security
- **Secrets**: Never commit credentials; use AWS Secrets Manager or IAM roles
- **JWTs**: Extract tenant from validated claim server-side, never from client input
- **WebSocket auth**: JWT in query param (browsers can't set headers on handshake), exclude from logs
- **Mutual TLS**: X.509 certs for edge device → IoT Core connection

## Documentation Standards

Shared roadmap and architecture docs belong in the workspace `docs/`. Increment specs belong in each project's `specs/` directory. Keep one README at each component directory; do not create README files in every component subdirectory. Do not create standalone task or completion reports; record completion in the owning project's `specs/tasks.md` and Progress summary table. Historical consolidated specs are preserved in `docs/archive/original-spec/` and do not govern current implementation.


### ADRs
- Status: Proposed / Accepted / Superseded
- Context: Problem statement
- Decision: Chosen approach with alternatives considered table
- Consequences: Positive, negative/trade-offs, out of scope
- References: Prior ADRs, external docs

### Design Documents
- Section 4: "Design decisions not covered by an existing requirement" (should be empty)
- Section 5: "Open design questions" (should be empty for Accepted specs)

### Task Documents
- Keep status column current; don't let it drift from actual repo state
- Update Progress summary table on wave completion
- Document blockers immediately with `blocked` status

## Testing Strategy

### Unit Tests
- Python: `pytest` with coverage targets
- JavaScript: Jest (when needed)
- Coverage goal: >80% for business logic, 100% for tenant isolation code

### Integration Tests
- Lambda + RDS interaction
- FastAPI endpoints with test database
- Edge agent MQTT publish/replay

### End-to-End Tests (Increment 3)
- Network failure recovery
- Tenant isolation verification
- Device reimage tolerance
- Load testing (100 readings/sec for 1 hour)
- Alerting performance
- Rollback validation

## Version Control

- **Three repos**: edge-agent, backend (Lambda + FastAPI), frontend
- **Branching**: Feature branches → PR → main
- **Deployment**: Auto-deploy on merge to main (Lambda, Fargate, Frontend); Manual for edge (OTA)

## Working with This Repo

### Starting a new task
1. Read the relevant project's `specs/requirements.md` to understand the "why"
2. Read the relevant project's `specs/design.md` to understand the "how"
3. Locate the task in the project's `specs/tasks.md` and check dependencies
4. Review the corresponding ADR for design rationale
5. Update task status to `in-progress`

### Completing a task
1. Verify all requirement IDs are satisfied
2. Update task status to `done`
3. Update Progress summary table
4. Check if dependent tasks are now unblocked

### Adding new features
1. Start with a new requirement in the increment project's `specs/requirements.md` (or create Increment 4)
2. Don't skip straight to design or code
3. Trace new requirements to existing or new ADRs
4. Update `specs/design.md` only after requirements are approved
5. Generate tasks from design, not from requirements directly

## References

- Start with the workspace `README.md` and `docs/INCREMENTS.md` for navigation
- Read `docs/INCREMENTS.md` for roadmap and success criteria
- All ADRs are Accepted — treat as immutable unless explicitly superseding with a new ADR
