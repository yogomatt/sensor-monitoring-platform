# Technology Stack

## Architecture Overview

Multi-layer IoT platform: Edge (Raspberry Pi) → AWS IoT Core → Lambda/RDS → FastAPI → React Dashboard

## Core Technologies by Layer

### Edge Layer
- **Runtime**: Python 3.9+, Docker containers
- **MQTT Client**: paho-mqtt with QoS 1, mutual TLS (X.509 certificates)
- **Local Storage**: SQLite with WAL (Write-Ahead Logging) mode
- **OTA Deployment**: AWS IoT Greengrass (Increment 3)

### Ingestion Layer
- **Message Broker**: AWS IoT Core with Rules Engine
- **Ingest Processing**: AWS Lambda (Python runtime)
- **Fan-out Pattern**: Rules Engine multi-action routing (Lambda + S3 + Alerting)

### Storage Layer
- **Operational Database**: TimescaleDB on RDS PostgreSQL (`db.t4g.micro`, Single-AZ)
- **Time-series**: Hypertables with 7-day chunks, compression after 7 days
- **Raw Archive**: S3 with Hive-style partitioning (`raw/{tenant_id}/year=/month=/day=/hour=`)
- **Lifecycle**: S3 Standard (90 days) → Glacier Instant Retrieval

### API Layer
- **Framework**: FastAPI (Python, async)
- **Deployment**: ECS/Fargate behind Application Load Balancer
- **Authentication**: AWS Cognito (Essentials tier) with JWT (RS256)
- **Real-time**: WebSocket endpoint for live updates
- **Rate Limiting**: slowapi (in-memory, per-task)

### Frontend Layer
- **Framework**: React with React Router
- **Charting**: Recharts
- **Hosting**: S3 + CloudFront (custom domain, HTTPS, SPA fallback)
- **Auth Flow**: Cognito redirect flow with sessionStorage

## Key Libraries & Dependencies

### Python (Edge Agent & Backend)
- `paho-mqtt` — MQTT client
- `fastapi` — API framework
- `uvicorn` — ASGI server
- `psycopg2-binary` — PostgreSQL driver
- `pydantic` — Data validation
- `python-jose[cryptography]` — JWT validation
- `slowapi` — Rate limiting

### JavaScript (Frontend)
- `react` / `react-dom`
- `react-router-dom` — Client-side routing
- `recharts` — Dashboard charts
- `@aws-amplify/auth` — Cognito integration

## Database Schemas

### Edge (SQLite)
```sql
sensor_readings (
    id, tenant_id, device_id, sensor_type, value, unit,
    timestamp, sequence_no, published_at, retry_count, created_at
)
```

### Cloud (TimescaleDB/PostgreSQL)
```sql
sensor_readings (time, tenant_id, device_id, sensor_type, value, unit, sequence_no)
    — hypertable, 7-day chunks, unique(device_id, sequence_no, time)

devices (device_id, tenant_id, display_name, location, firmware_version, registered_at, active)

device_heartbeats (time, tenant_id, device_id, agent_version, buffer_depth, uptime_seconds)
    — hypertable

device_errors (time, tenant_id, device_id, sensor_type, error_code, message)
    — hypertable

alert_rules (id, tenant_id, device_id, sensor_type, condition, threshold, notification_channel, active)
    — Increment 2
```

## Common Commands

### Edge Agent
```bash
# Build Docker image
docker build -t edge-agent:latest .

# Run locally for testing
docker run --rm -v ./data:/data edge-agent:latest

# Push to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
docker tag edge-agent:latest <account>.dkr.ecr.us-east-1.amazonaws.com/edge-agent:latest
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/edge-agent:latest
```

### Backend (FastAPI)
```bash
# Install dependencies
pip install -r requirements.txt

# Run locally
uvicorn main:app --reload --host 0.0.0.0 --port 8000

# Deploy to ECS (via GitHub Actions or manual)
# See iot-sensor-fleet-devops/specs/design.md for CI/CD workflows
```

### Frontend (React)
```bash
# Install dependencies
npm install

# Run dev server (DO NOT use for production)
npm run dev

# Build for production
npm run build

# Deploy to S3 (via GitHub Actions or manual)
aws s3 sync build/ s3://<bucket-name>/ --delete
aws cloudfront create-invalidation --distribution-id <dist-id> --paths "/*"
```

### Database
```bash
# Connect to RDS
psql -h <rds-endpoint> -U postgres -d iot_platform

# Create hypertable
SELECT create_hypertable('sensor_readings', 'time', chunk_time_interval => INTERVAL '7 days');

# Add compression policy
ALTER TABLE sensor_readings SET (timescaledb.compress, timescaledb.compress_segmentby = 'tenant_id, device_id, sensor_type');
SELECT add_compression_policy('sensor_readings', INTERVAL '7 days');

# Add retention policy
SELECT add_retention_policy('sensor_readings', INTERVAL '30 days');
```

## Testing

### Edge Agent
```bash
# Run unit tests
pytest tests/
```

### Backend
```bash
# Run unit tests
pytest tests/ -v

# Run with coverage
pytest --cov=app tests/
```

### End-to-End (Increment 3)
```bash
# Network failure test
pytest tests/e2e/test_offline_recovery.py

# Tenant isolation test
pytest tests/e2e/test_tenant_isolation.py

# Load test (100 readings/sec for 1 hour)
python tests/load/generate_load.py --devices 10 --rate 100 --duration 3600
```

## Infrastructure Provisioning

All infrastructure uses AWS native services. No Terraform or CDK at MVP (manual provisioning). CDK introduced in Increment 3.

Key services to provision:
- RDS PostgreSQL with timescaledb extension
- AWS IoT Core endpoint + device registry
- Cognito User Pool (Essentials tier) with custom attribute `custom:tenant_id`
- S3 buckets (raw archive, frontend static assets)
- CloudFront distribution
- ECS cluster + Fargate service
- Lambda functions (ingestor, alerting)
- ALB with HTTPS listener

## Design Constraints

- **No third-party managed services**: No Timescale Cloud, no managed Grafana
- **No Kinesis**: IoT Rules Engine multi-action routing covers fan-out needs
- **No Redis**: In-memory rate limiting sufficient at launch scale
- **No RDS Proxy**: Not needed at <10 concurrent connections
- **Single-AZ RDS**: Multi-AZ deferred until scale warrants it

## Development Environment

- Python 3.9+
- Node.js 18+ / npm 9+
- Docker 20+
- AWS CLI v2
- psql (PostgreSQL client)
