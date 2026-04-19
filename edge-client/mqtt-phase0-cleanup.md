# MQTT Phase 0 Cleanup

This document tracks the pre-MQTT cleanup pass that removes fallback-era behavior before implementing MQTT-first device connectivity.

## Scope Completed

- Removed API in-memory fallback for `device_events` writes and reads.
- Removed API fallback guards that silently returned empty command lists when `device_commands` table was missing.
- Removed HTTP live/control endpoints replaced by MQTT in Phase 1 planning:
  - `POST /devices/heartbeat`
  - `GET /devices/{device_id}/commands/pending`
  - `PATCH /devices/{device_id}/commands/{command_id}/status`
  - `WS /devices/{device_id}/commands/stream`
  - `POST /device-events/ingest`
  - `WS /device-events/ws`
  - preview request/frame endpoints under `/devices/{device_id}/preview/*`
- Removed legacy edge workers tied to the deleted endpoints:
  - `src/heartbeat.py`
  - `src/command_consumer.py`
  - `src/websocket_command_client.py`
  - `src/preview_relay.py`
- Converted edge `event_client` to no-op until MQTT event transport is implemented.
- Added destructive DB cleanup script: `api-server/tools/mqtt_phase0_cleanup.sql`.

## Breaking Changes

- API now requires `device_events` table to exist for persisted events.
- API now only supports dashboard-side command queue APIs for device commands.
- Dashboard logs and invalidation are polling-based until MQTT live feed integration.

## Manual DB Action

Run `api-server/tools/mqtt_phase0_cleanup.sql` after backup.

## Next Phase (Phase 1)

- Introduce MQTT broker and per-device credentials.
- Replace websocket command delivery with MQTT command topics.
- Replace heartbeat with MQTT presence/last-will and telemetry topics.
- Keep scan upload path until media plane migration is complete.

## Phase 1 Progress (Skeleton)

- API server now includes an MQTT bridge service (`app/services/mqtt_bridge.py`) started during app lifespan.
- API command queue publishes new commands to MQTT topic: `ricevision/devices/{device_id}/commands/{command_id}`.
- API bridge subscribes to MQTT topics for `presence`, `telemetry`, `logs`, and `acks`.
- Edge client now starts `src/mqtt_agent.py` when `MQTT_ENABLED=true`.
- Edge MQTT agent publishes retained presence and periodic telemetry.
- Edge MQTT agent subscribes to command topic and publishes command acknowledgements.
- Edge `event_client` now writes a local event queue consumed by MQTT agent for log publication.

## Phase 1.5 Hardening (Completed)

- Added MQTT TLS settings on API and edge (`*_TLS_ENABLED`, CA path, insecure toggle).
- Added MQTT reconnect backoff settings on API and edge.
- Added schema version field in MQTT payloads.
- Added edge command idempotency guard to ignore duplicate command IDs.
- Added API-side terminal status guard when applying command acknowledgements.

## Phase 2 Live Stream (Completed)

- API now exposes server-sent events endpoint: `/live/events?token=<jwt>`.
- MQTT bridge now fans out MQTT events to authenticated live subscribers.
- Dashboard invalidation hook now consumes live SSE stream.
- Logs page now appends incoming MQTT log events from SSE in near-real time.

## Phase 3 Camera Streaming (Completed)

- Added API camera control endpoints:
  - `POST /devices/{device_id}/stream/start`
  - `POST /devices/{device_id}/stream/stop`
- Added camera stream command support in device command schema:
  - `camera-stream-start`
  - `camera-stream-stop`
- Edge MQTT agent now supports camera stream sessions and publishes base64 JPEG frames on topic `.../camera`.
- MQTT bridge now subscribes to camera channel and fans out camera events to live SSE subscribers.
- Dashboard `DevicesPage` now has start/stop stream controls and renders live frames from SSE camera events.

## Phase 3.5 Stream Guardrails (Completed)

- Added API-configurable stream caps (`MQTT_CAMERA_STREAM_MAX_FPS`, `MQTT_CAMERA_STREAM_MIN_DURATION_SECONDS`, `MQTT_CAMERA_STREAM_MAX_DURATION_SECONDS`) and clamp logic in stream start endpoint.
- Added API camera payload validation with max frame size (`MQTT_CAMERA_MAX_FRAME_BYTES`) before SSE fanout.
- Added edge-side max frame size guard (`MQTT_CAMERA_MAX_FRAME_BYTES`) to drop oversized frames before MQTT publish.
- Added dashboard defaults for requested stream fps/duration using env overrides (`VITE_CAMERA_STREAM_DEFAULT_FPS`, `VITE_CAMERA_STREAM_DEFAULT_DURATION_SECONDS`).

## Phase 4 Live Transport Reliability (Completed)

- Added shared dashboard live SSE client (`web-dashboard/src/lib/liveMqttSse.ts`) with:
  - single shared EventSource connection
  - automatic reconnect with exponential backoff
  - fresh JWT fetch before each reconnect attempt
- Migrated dashboard live consumers to shared subscription API:
  - `useDeviceEventsLiveInvalidation`
  - `DevicesPage` camera frame listener
- This removes duplicate SSE connections per page and improves resilience when live transport disconnects.

## Phase 5 Live Auth Session Handling (Completed)

- Updated shared dashboard SSE client to observe Supabase auth state changes.
- On `TOKEN_REFRESHED`/`SIGNED_IN`, the live connection is rotated to use a fresh JWT in the SSE URL.
- On `SIGNED_OUT`, live connection state is torn down immediately and reconnect is stopped.
- This avoids stale-token live connections and improves behavior during login/session refresh/logout transitions.

## Phase 6 Live Connection Observability (Completed)

- Fixed dashboard TypeScript config deprecation by setting `ignoreDeprecations` for TS 6 compatibility.
- Added shared live transport connection status signaling in `web-dashboard/src/lib/liveMqttSse.ts`.
- Devices page now displays live transport state (`idle`, `connecting`, `reconnecting`, `connected`) in camera overlay and monitoring notes.
- Completed full repository error sweep after Phase 6 updates.
