# MVP

Core sensor collection, durable edge buffering, ingestion, tenant isolation, authentication, and the real-time dashboard.

Start here. Later increments remain deferred until this increment is complete and stable.

- [Requirements](specs/requirements.md): increment scope and requirement IDs.
- [Design](specs/design.md): component behavior and architecture.
- [Tasks](specs/tasks.md): dependencies and current implementation progress.
- [Shared ADRs](../docs/adr/README.md): architectural rationale.

Keep increment specifications in `specs/` and implementation documentation with its owning component.

The existing [edge agent](edge-agent/README.md) contains the SQLite schema implementation for T-1.1.

[Workspace guide](../README.md)
