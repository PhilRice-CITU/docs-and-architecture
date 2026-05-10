-- Migration: Remove MQTT-specific tables
-- Date: 2026-05-10
-- Reason: MQTT integration was removed. device_commands and device_events
--         existed solely to support MQTT pub/sub command routing and telemetry.
--
-- NOTE: edge_sessions is intentionally kept — it tracks grading/training
--       session state (operator, variety, batches) and is still used via REST.

-- Drop indexes first (Postgres drops them with the table, but explicit is safer)
DROP INDEX IF EXISTS idx_device_commands_device_id_created_at;
DROP INDEX IF EXISTS idx_device_events_created_at;
DROP INDEX IF EXISTS idx_device_events_device_id_created_at;

-- Drop tables (no inter-dependencies between these two; both FK only to devices)
DROP TABLE IF EXISTS device_commands;
DROP TABLE IF EXISTS device_events;
