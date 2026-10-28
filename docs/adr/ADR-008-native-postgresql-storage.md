# ADR-008 — Native PostgreSQL partitioning and manual operational data purging

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-09-23 |
| **Deciders** | Product owner |
| **Supersedes** | [ADR-004 — Processing & storage](ADR-004-processing-storage.md) |
| **Applies to** | MVP, Enterprise, and Fleet DevOps; final product scope |
| **Related requirements** | R-STO-1, R-ING-2, R-ING-5, R-EDGE-7, R-TEN-1, R-TEN-2, R-ALERT-3, R-STO-6, R-STO-7, R-NFR-4, R-CICD-6 |
| **Retired requirements** | R-STO-2, R-STO-3, R-STO-4, R-STO-5 |

## Context

ADR-004 selected TimescaleDB on Amazon RDS PostgreSQL. RDS does not offer the `timescaledb` extension in its supported extension matrix, so that deployment cannot be implemented as specified. This blocked MVP task T-1.3.

The product owner chose native PostgreSQL partitioning on RDS, removed compression and rollups from the final product, and chose manual purging while studying application performance. Automatic purging may become a future feature only if needed.

This ADR supersedes ADR-004 as the governing storage decision. ADR-004 remains unchanged as historical context. Its alert-rule store and independent S3 archive decisions are carried forward below; their implementation remains in the existing increments.

## Decision 1 — Native PostgreSQL on RDS

Use RDS PostgreSQL 15, `db.t4g.micro`, Single-AZ, with native declarative range partitioning. No TimescaleDB extension is required. Existing RDS networking choices remain in the MVP design; Multi-AZ and RDS Proxy remain deferred.

Partition `sensor_readings` by the device reading timestamp, `RANGE (time)`, in non-overlapping 7-day UTC intervals. Preserve ADR-004's reading columns and types, tenant scoping, indexes, and deduplication key. Ingestion and application queries address the parent table.

```sql
CREATE TABLE sensor_readings (
    time          TIMESTAMPTZ      NOT NULL,
    tenant_id     TEXT             NOT NULL,
    device_id     TEXT             NOT NULL,
    sensor_type   TEXT             NOT NULL,
    value         DOUBLE PRECISION NOT NULL,
    unit          TEXT             NOT NULL,
    sequence_no   BIGINT           NOT NULL,
    CONSTRAINT uq_device_seq UNIQUE (device_id, sequence_no, time)
) PARTITION BY RANGE (time);

-- Example partition; operational intervals must cover actual reading timestamps.
CREATE TABLE sensor_readings_20260921 PARTITION OF sensor_readings
    FOR VALUES FROM ('2026-09-21 00:00:00+00')
               TO ('2026-09-28 00:00:00+00');

CREATE INDEX ON sensor_readings (tenant_id, device_id, time DESC);
CREATE INDEX ON sensor_readings (tenant_id, sensor_type, time DESC);
```

The unique constraint includes the partition key, as PostgreSQL requires. Continue using `ON CONFLICT (device_id, sequence_no, time) DO NOTHING`. A device sequence reset remains distinguishable by timestamp. No surrogate reading ID or external deduplication store is introduced.

`devices` and `alert_rules` remain ordinary relational tables. Their increment-specific fields and delivery scope remain as defined in their specs. If the deferred `device_heartbeats` and `device_errors` storage is implemented under a future spec, use the same native time-partitioning pattern rather than hypertables; this ADR does not schedule those features.

### Partition creation and replay

Partition creation is separate from purging. MVP T-2.4 supplies a procedure to create partitions for current and future intervals and timestamps arriving through offline replay. Initially, operators provision these intervals and check coverage before ingestion; no partition scheduler or extension is required by this decision.

PostgreSQL does not automatically create a missing partition. A missing-partition insert must remain a failed ingestion eligible for retry, never be treated as successful or silently discarded. Operators must ensure the appropriate partition exists before retrying, including for late readings. The 30-day purge cutoff is not an instruction to reject older replayed data.

## Decision 2 — Manual purge; retain at least 30 days

Keep R-STO-1's minimum of **at least 30 days of raw readings**, measured from device reading time. Thirty days is a minimum retention window, not an automatic expiration deadline or an upper storage bound. Data remains until the operator explicitly purges it.

MVP T-2.6 supplies and verifies the manual purge procedure:

1. Inspect partition bounds and choose an explicit UTC cutoff no later than the current time minus 30 days.
2. Review the readings/time intervals to be removed and any pending replay affecting those intervals.
3. Remove only partitions whose exclusive upper bound is at or before that cutoff. Never remove a partition containing readings in the protected 30-day window.
4. Verify the remaining partition coverage and recent data after the operation.

Dropping an eligible partition deletes its rows. Detaching alone removes it from parent-table queries but retains a standalone table and does not reclaim its storage. The runbook must distinguish these operations and account for their locking behavior.

Whole-partition purging can keep almost seven extra days at the boundary. Delaying manual purge retains data longer without limit. Manual purge is intentional data removal; it does not relax durability during ingestion or offline replay.

No scheduled `DELETE`, partition-drop job, automatic retention policy, `pg_cron` purge schedule, or `pg_partman` retention policy is part of any current increment. Automatic purging requires a future approved requirement, design, and task if performance/operational evidence warrants it. This decision does not change edge SQLite buffer maintenance, deployment-artifact retention, backups, or S3 storage-class transitions.

## Decision 3 — Remove compression and rollups from the product

Remove time-series compression, continuous aggregates, materialized rollup tables, aggregate-refresh jobs, and raw-versus-rollup query routing from both the MVP and final product. R-STO-2 through R-STO-5 are retired, not deferred. Their IDs must not be reused.

Dashboard/API queries use retained raw `sensor_readings` with tenant/device/time filters, existing pagination, and the partitioned indexes. Data intentionally purged from RDS is no longer returned by the readings API. The S3 archive is not an automatic dashboard fallback. Ordinary SQL aggregation for an individual query is not a maintained rollup feature; PostgreSQL's internal storage behavior is not a requested compression feature.

## Decision 4 — Carry forward alerting and archive decisions

- Keep tenant-scoped alert rules in the same operational PostgreSQL database (R-ALERT-3). No separate alert-rule store is introduced.
- Keep the independent IoT Rules Engine S3 raw archive in Enterprise (R-STO-6/R-STO-7), with the existing tenant/time key convention: `raw/{tenant_id}/year={YYYY}/month={MM}/day={DD}/hour={HH}/{device_id}_{timestamp}_{sequence_no}.json`.
- Preserve the permanent, uncompressed S3 archive with no object expiry and its Standard-to-Glacier Instant Retrieval transition after 90 days. Manual RDS purge does not delete archived objects.
- Preserve existing deduplication, application-layer tenant isolation, and device timestamp semantics. This decision does not add role or API features.

## Consequences

- T-1.3 is unblocked architecturally but remains pending until RDS is actually provisioned and verified.
- RDS can implement the selected storage model without an unsupported extension.
- Operators take responsibility for partition coverage and manual purge; storage can grow indefinitely between purges.
- Native partitioning supplies partition pruning and efficient bulk removal, but does not provide TimescaleDB compression or continuous aggregates.
- Performance and costs must be measured against actual retained data volume. Prior compression savings and aggregate-based latency assumptions in ADR-004 no longer apply. R-NFR-4 remains a validation target, not an assertion that unbounded raw storage will meet it.
- No infrastructure is provisioned by this documentation change.

## Implementation traceability

| Requirement | Task(s) | Change |
|---|---|---|
| R-STO-1 | T-1.3 | Provision ordinary RDS PostgreSQL; remove TimescaleDB dependency |
| R-STO-1, R-ING-2, R-EDGE-7, R-TEN-1, R-TEN-2 | T-2.4 | Native partition schema, compatible deduplication/indexes, partition creation procedure |
| R-STO-1 | T-2.6 | Manual purge runbook and verification instead of automatic retention |
| R-STO-2 through R-STO-5 | T-E2-1.2, T-E2-1.3, T-E2-1.4, T-E2-3.2, T-E2-4.3, T-E2-5.3, T-E2-5.8 | Retire requirements and tasks; remove downstream dependencies |
| R-CICD-6 | T-I3-1.3 | CDK database stack uses native PostgreSQL without removed features |

Existing alerting/archive tasks remain in scope. Task IDs are preserved; retired tasks do not count as completed implementation.

## References

- [ADR-004 — superseded storage decision](ADR-004-processing-storage.md)
- [AWS RDS supported PostgreSQL extensions](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html)
- [PostgreSQL 15 declarative partitioning, constraints, and maintenance](https://www.postgresql.org/docs/15/ddl-partitioning.html)
- [MVP requirements](../../iot-sensor-mvp/specs/requirements.md), [design](../../iot-sensor-mvp/specs/design.md), [tasks](../../iot-sensor-mvp/specs/tasks.md)
- [Enterprise requirements](../../iot-sensor-enterprise/specs/requirements.md), [tasks](../../iot-sensor-enterprise/specs/tasks.md)
