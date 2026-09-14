-- SQLite schema for edge agent offline buffer
-- Implements write-ahead queue pattern with mark-as-sent tracking
-- Based on ADR-002: Edge layer — MQTT topic structure and SQLite offline buffer
-- Date: 2026-07-26

-- ============================================================================
-- Configuration: Enable WAL mode for crash safety and concurrent reads
-- ============================================================================
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA foreign_keys = ON;

-- ============================================================================
-- Table: sensor_readings
-- Purpose: Write-ahead buffer for sensor readings before MQTT publish
-- Pattern: Read sensor → Insert with published_at=NULL → Publish → Mark sent
-- Replay: Query WHERE published_at IS NULL ORDER BY timestamp ASC LIMIT 50
--
-- Operational constraints (from ADR-002):
--   - Max buffer rows: 100,000 (~347 days at 5 sensors × 5-min polling)
--   - Post-publish retention: 7 days (audit window before purge)
--   - Replay batch size: 50 rows per cycle
--   - Application layer responsible for purge (not via trigger)
-- ============================================================================
CREATE TABLE IF NOT EXISTS sensor_readings (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    tenant_id     TEXT    NOT NULL,
    device_id     TEXT    NOT NULL,
    sensor_type   TEXT    NOT NULL,
    value         REAL    NOT NULL,
    unit          TEXT    NOT NULL,
    timestamp     TEXT    NOT NULL,
    sequence_no   INTEGER NOT NULL,
    published_at  TEXT    DEFAULT NULL,
    retry_count   INTEGER DEFAULT 0,
    created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Index for efficient pending-row queries during replay cycle
-- Partial index: only indexes rows where published_at IS NULL
-- Used by replay loop: SELECT * FROM sensor_readings 
--                      WHERE published_at IS NULL 
--                      ORDER BY timestamp ASC LIMIT 50
CREATE INDEX IF NOT EXISTS idx_pending ON sensor_readings (published_at, timestamp)
    WHERE published_at IS NULL;

-- Index for audit/inspection: find rows by device and time range
CREATE INDEX IF NOT EXISTS idx_device_time ON sensor_readings (device_id, timestamp);

-- ============================================================================
-- Table: heartbeats
-- Purpose: Track agent health telemetry (version, buffer depth, uptime)
-- Published to: iot/{tenant_id}/{device_id}/status/heartbeat
-- Retention: Same 7-day window as sensor_readings (application-managed purge)
-- ============================================================================
CREATE TABLE IF NOT EXISTS heartbeats (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp      TEXT    NOT NULL,
    agent_version  TEXT    NOT NULL,
    buffer_depth   INTEGER NOT NULL,
    uptime_seconds INTEGER NOT NULL,
    published_at   TEXT    DEFAULT NULL,
    created_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Index for pending heartbeats (same replay pattern as sensor_readings)
CREATE INDEX IF NOT EXISTS idx_heartbeat_pending ON heartbeats (published_at, timestamp)
    WHERE published_at IS NULL;
