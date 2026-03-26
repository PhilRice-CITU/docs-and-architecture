# Edge Client — Full Codebase Review

## Architecture Overview

The edge client is a **Raspberry Pi-based image capture and upload system** with this data flow:

```
Button Press (GPIO 27) → capture.sh → saves IR + White images
                                    ↓
                              enqueue_capture.py → upload_queue.json
                                    ↓
                              uploader.py (polls every 3s)
                                    ↓
                              upload_router.py → API server OR Roboflow
                                    
Meanwhile:  heartbeat.py → pings API every 60s ("I'm alive")
            app.py (Flask) → local HTTP endpoints for monitoring
```

---

## File-by-File Breakdown

### Shell Scripts (Orchestration Layer)

**startup.sh** — Main entry point. Loads all libraries, acquires a process lock, loads `.env`, starts all services (Flask, uploader, heartbeat, capture), launches Electron kiosk. Ends with an empty `while true; sleep 5` loop.

**lib/env.sh** — Loads `.env` via `set -o allexport`, validates required vars (`DEVICE_ID`, `API_BASE_URL`), sets defaults for ~15 optional vars (ports, timeouts, paths, modes).

**lib/log.sh** — Colored logging utilities: `log_info`, `log_ok`, `log_warn`, `log_error`, `log_fatal`, `log_section`. Detects TTY for color, writes to `$LOG_FILE`.

**lib/lock.sh** — Single-instance guard using PID file at `/tmp/edge-client.lock`. Checks for stale locks from dead processes.

**lib/services.sh** — Spawns Python/shell services in background, tracks PIDs in an associative array. `wait_for_flask()` polls `/health` up to 30 times. `shutdown_all()` sends SIGTERM to all tracked services.

**lib/display.sh** — Detects X11/Wayland display, attempts `startx` if missing, falls back to headless. `launch_kiosk()` runs Electron via `npx electron . --no-sandbox`.

**scripts/capture.sh** — Hardware capture daemon. Polls GPIO 27 for button press. On press: switches relay (GPIO 17) to IR mode, captures with `rpicam-still`, switches to white light, captures again, then calls `enqueue_capture.py` to queue both images. Debounces button on release.

### Python Files (Service Layer)

**src/app.py** — Flask server (port 5055) with 4 read-only endpoints:
- `GET /health` → `{"status": "ok"}`
- `GET /mode` → current mode + upload targets
- `GET /queue-size` → count of pending uploads
- `GET /status` → device ID, mode, disk image count, queue length

**src/enqueue_capture.py** — CLI tool. Takes `--raw`, `--ir`, `--session`, `--device`, `--captured-at`, `--queue` args. Appends a JSON object `{raw, ir, session_id, device_id, captured_at, retries: 0}` to the queue file.

**src/uploader.py** — Background worker. Polls `upload_queue.json` every 3s, dequeues items one at a time, calls `upload_router.upload_item()`. On failure, requeues with incremented retry count (max 5). Items exceeding max retries are silently dropped.

**src/upload_router.py** — Routing logic. `resolve_upload_target()` determines whether to send to API or Roboflow based on `EDGE_MODE` (production/training) and target config. `upload_to_api()` POSTs both images as multipart. `upload_to_roboflow()` uploads each image separately to Roboflow's dataset API.

**src/heartbeat.py** — Infinite loop that POSTs `{"device_id": ..., "status": "online"}` to the API heartbeat endpoint every 60 seconds. All exceptions are silently caught.

---

## What's Working

- Core pipeline (capture → queue → upload) is **fully implemented end-to-end**
- Upload routing (API vs Roboflow based on mode) is **complete**
- Boot orchestration with library separation is **well-structured**
- Heartbeat reporting is **functional**
- Flask monitoring endpoints are **operational**
- Process locking prevents duplicate instances
- Config-driven via `.env` with sensible defaults

---

## What You're Lacking (Prioritized)

### CRITICAL — Will cause data loss or system failures

| # | Issue | Where | Details |
|---|-------|-------|---------|
| 1 | **Race condition on queue file** | uploader.py, enqueue_capture.py | Both read-modify-write `upload_queue.json` without file locking. If `capture.sh` enqueues while `uploader.py` dequeues simultaneously, items get lost. Need `fcntl.flock()` or atomic write-then-rename. |
| 2 | **No service monitoring** | startup.sh | The main loop is `while true; sleep 5; done` — it does nothing. If Flask, uploader, or heartbeat crashes after startup, it stays dead forever. Need a watchdog loop that checks `service_alive()` and restarts. |
| 3 | **Dead-letter queue missing** | uploader.py | After 5 failed retries, items are silently discarded with `return`. No dead-letter file, no logging. Permanently lost data with no way to debug why. |
| 4 | **File handle leak** | upload_router.py | `upload_to_api()` opens files in a dict for multipart upload but doesn't use `with` statements properly. If `requests.post()` throws, file handles leak. After ~1024 failures, the process will crash. |

### HIGH — Causes silent failures or misreported data

| # | Issue | Where | Details |
|---|-------|-------|---------|
| 5 | **Zero logging in all Python files** | All `src/*.py` | No `print()`, no `logging` module. Successes, failures, retries, uploads — all invisible. You can't debug anything in production. |
| 6 | **Hardcoded `"mode": "production"`** | upload_router.py | `upload_to_api()` always sends `"mode": "production"` regardless of actual `EDGE_MODE`. Training uploads are misreported to the API. |
| 7 | **No input validation on enqueue** | enqueue_capture.py | Doesn't check if `--raw`/`--ir` files actually exist, doesn't validate timestamp format, no duplicate detection. Queue can fill with garbage entries. |
| 8 | **GPIO pins hardcoded** | scripts/capture.sh | `RELAY=17` and `BUTTON=27` are hardcoded, not pulled from `.env`. If you change hardware wiring, you must edit the script. |
| 9 | **Silent exception swallowing** | heartbeat.py | `except Exception: pass` on every heartbeat. Network down? Auth failed? API changed? You'll never know. |

### MEDIUM — Operational and robustness issues

| # | Issue | Where | Details |
|---|-------|-------|---------|
| 10 | **No exponential backoff** | uploader.py | Retries every 3 seconds regardless of failure type. If API is down, you hammer it 20 times/minute for nothing. |
| 11 | **No log rotation** | lib/log.sh | Logs grow unbounded. On a Pi running 24/7, disk fills up eventually. |
| 12 | **Secrets printed to logs** | lib/env.sh | API keys/URLs can appear in startup logs. No masking. |
| 13 | **No image cleanup** | upload_router.py | Successfully uploaded images are never deleted from disk. `data/images/` grows forever. |
| 14 | **No camera error handling** | scripts/capture.sh | If `rpicam-still` fails or hangs, the script continues as if capture succeeded. No timeout, no validation of output files. |
| 15 | **Flask has no auth** | src/app.py | All endpoints are public. Anyone on the network can query device status. |

### NOT IMPLEMENTED — Entire features missing

| # | Feature | Where | Status |
|---|---------|-------|--------|
| 16 | **Electron UI** | `electron/` | Directory is completely empty. No `package.json`, no `main.js`, no renderer files. The kiosk UI doesn't exist. |
| 17 | **Ansible provisioning** | `ansible/` | Empty directory. No playbooks for automated Pi setup. |

---

## Documentation Status

| Doc | Status | Issue |
|-----|--------|-------|
| README.md | Good | Current and accurate |
| EDGE_CLIENT_ORCHESTRATION.md | Good | Comprehensive architecture docs |
| EDGE_CLIENT_STEP_BY_STEP_LEARNING_GUIDE.md | Outdated | Some template code is superseded by actual implementations |
| UPLOAD_ROUTING_TRAINING_VS_PRODUCTION.md | Outdated | Says routing is "planned later" but it's already implemented in `upload_router.py` |

---

## Recommended Fix Order

If you're starting again, tackle these in order:

1. **Add file locking to queue operations** (fixes #1) — prevents data loss
2. **Add Python logging** (fixes #5) — you need visibility before fixing anything else
3. **Add service watchdog loop in startup.sh** (fixes #2) — keeps services alive
4. **Implement dead-letter queue** (fixes #3) — stop losing failed items
5. **Fix file handle leak with `with` statements** (fixes #4)
6. **Fix hardcoded production mode** (fixes #6)
7. **Add input validation to enqueue** (fixes #7)
8. **Add exponential backoff to uploader** (fixes #10)
9. **Make GPIO pins configurable** (fixes #8)
10. **Build Electron UI** (fixes #16) — large feature, do last
