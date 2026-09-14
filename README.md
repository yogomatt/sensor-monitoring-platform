# IoT Sensor Monitoring Platform

This workspace holds shared architecture decisions, three delivery increments, and their implementation. Work starts with the MVP; each later increment depends on the previous increment being complete and stable.

| Project | Scope | Documentation |
|---|---|---|
| MVP | Core sensor → dashboard pipeline | [Project guide](iot-sensor-mvp/README.md) |
| Enterprise | Alerting, RBAC, retention, archive | [Project guide](iot-sensor-enterprise/README.md) |
| Fleet & DevOps | OTA, CI/CD, testing, operations | [Project guide](iot-sensor-fleet-devops/README.md) |

Shared documents live in [docs/](docs/README.md): the [roadmap](docs/INCREMENTS.md) and [architecture decisions](docs/adr/README.md). Original consolidated specs are preserved in [the archive](docs/archive/README.md).

Each project's `specs/requirements.md`, `specs/design.md`, and `specs/tasks.md` is authoritative for that increment. Track implementation status in its task file. Component usage documentation stays beside its source.

Agent instructions remain in [AGENTS.md](AGENTS.md), with workspace steering in [.kiro/steering/](.kiro/steering/structure.md).
