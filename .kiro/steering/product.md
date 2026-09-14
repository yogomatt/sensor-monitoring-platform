# Product Overview

## What We're Building

An IoT sensor monitoring platform that collects readings from Raspberry Pi edge devices and displays them on a multi-tenant, real-time dashboard. The platform guarantees zero data loss during network outages and provides authenticated access with tenant isolation.

## Core Value Propositions

- **Zero data loss**: Write-ahead SQLite buffer on edge devices ensures readings survive network outages
- **Multi-tenant SaaS**: Complete tenant isolation from edge to dashboard
- **Real-time visibility**: WebSocket-fed dashboards with live sensor updates
- **Cost-efficient**: ~$54/month at 10-device scale using AWS-native services

## Key Use Cases

1. **Sensor data collection**: Temperature, humidity, proximity readings from industrial equipment
2. **Fleet management**: Deploy and update edge agent software across distributed devices
3. **Operational monitoring**: Dashboard visibility into device health, buffer depth, and sensor errors
4. **Alerting** (Increment 2): Threshold-based notifications for sensor anomalies

## Incremental Delivery Model

The platform is built in three independent increments:

- **Increment 1 (MVP)**: End-to-end sensor → dashboard pipeline with 30-day storage
- **Increment 2 (Enterprise)**: Adds alerting, RBAC, data retention/compression, permanent archive
- **Increment 3 (Fleet DevOps)**: Staged OTA updates, CI/CD pipelines, comprehensive testing

## Target Scale at Launch

- 10 devices
- Single-digit tenant count
- 5 sensors per device (temperature, humidity, proximity)
- 5-minute polling interval
- ~14,400 readings/day

## Design Philosophy

- **AWS-native first**: Prefer managed AWS services over third-party equivalents
- **Architectural coherence**: Keep all components in the same ecosystem
- **Incremental complexity**: Don't add infrastructure until a documented trigger is reached
- **Crash safety**: Write-ahead patterns for all data capture
- **Tenant isolation**: Application-layer scoping, not database-level RLS (at launch scale)
