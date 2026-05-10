# edge-client — Coding Specification

**Status:** Ready to code  
**Pi target:** Raspberry Pi 4/5, Raspberry Pi OS Lite 64-bit  
**Camera:** Raspberry Pi Camera Module 3 NoIR (or HQ Camera NoIR)

This document is the single source of truth for building the `edge-client` repo. Read this before writing any code.

> **Note:** MQTT integration was removed in 2026-05-10. Any reference to `mqtt_agent.py`, MQTT topics, MQTT env vars, or `start_service "mqtt-agent"` in this spec is stale.

---

## Repository Structure

Create this layout exactly:

```
edge-client/
├── .env.example
├── .env.age              ← encrypted secrets, committed to Git
├── .gitignore
├── startup.sh
├── provision.sh
│
├── lib/
│   ├── log.sh
│   ├── env.sh
│   ├── lock.sh
│   ├── display.sh        ← updated: launches Electron instead of Chromium
│   └── services.sh
│
├── src/
│   ├── app.py
│   ├── uploader.py
│   ├── heartbeat.py
│   └── queue_manager.py
│
├── scripts/
│   └── capture.sh
│
├── electron/             ← NEW: Electron UI layer
│   ├── package.json
│   ├── main.js           ← BrowserWindow, kiosk mode, waits for Flask
│   ├── preload.js        ← exposes safe APIs to renderer
│   └── renderer/
│       ├── index.html    ← three screens: mode select, WiFi, capture
│       ├── index.js      ← fetch() calls to Flask API on localhost:5000
│       └── styles.css
│
├── data/                 ← gitignored, created at runtime
│   ├── images/
│   └── logs/
│
└── ansible/
    ├── playbook.yml
    └── inventory.ini
```

`.gitignore` must contain:

```
.env
data/
*.pyc
__pycache__/
electron/node_modules/
electron/dist/
```

---

## Environment Variables

### `.env.example` — commit this

```env
# Device identity
DEVICE_ID=pi-001
DEVICE_SECRET=

# API server
API_BASE_URL=https://your-api-server.com

# Optional overrides (defaults shown)
FLASK_PORT=5000
DISPLAY_MODE=auto
CAPTURE_WIDTH=1920
CAPTURE_HEIGHT=1080
CAPTURE_QUALITY=90
CAMERA_WARMUP_MS=2000
CAPTURE_DELAY_MS=500
HEARTBEAT_INTERVAL_SECONDS=60
IMAGE_DIR=./data/images
LOG_LEVEL=INFO

# Logging destination — /tmp/logs means RAM, wiped on reboot, zero SD card wear.
# Change to ./data/logs only if you need logs to survive reboots (e.g. deep debugging).
LOG_DIR=/tmp/logs

# Electron
ELECTRON_DEV=false          # set to true on laptop to open DevTools + disable kiosk
```

### How secrets work on the Pi

1. You write a real `.env` on your laptop
2. Encrypt it: `age -r <pi-public-key> -o .env.age .env`
3. Commit `.env.age` to Git — this is safe, it's encrypted
4. Delete the plaintext `.env` from your laptop
5. On the Pi, systemd decrypts it before startup: `age -d -i ~/.keys/grainbot.key -o .env .env.age`
6. `.env` exists on Pi disk only during the session, never in Git

---

## `lib/log.sh`

**Purpose:** Logging functions available to all other scripts.  
**Used by:** Every other lib file, startup.sh  
**How to test:** `source lib/log.sh && log_info "test" && log_ok "good" && log_warn "watch" && log_error "bad"`

```bash
#!/bin/bash
[ -n "${_LOG_SH_LOADED:-}" ] && return 0
_LOG_SH_LOADED=1

# Only colorize if stdout is a terminal
if [ -t 1 ]; then
    _RED='\033[0;31m'; _GREEN='\033[0;32m'
    _YELLOW='\033[1;33m'; _CYAN='\033[0;36m'
    _DIM='\033[2m'; _NC='\033[0m'
else
    _RED=''; _GREEN=''; _YELLOW=''; _CYAN=''; _DIM=''; _NC=''
fi

# LOG_DIR defaults to /tmp/logs (RAM — wiped on reboot, zero SD card wear).
# Override in .env to ./data/logs only if you need persistent logs.
LOG_DIR="${LOG_DIR:-/tmp/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/startup.log}"

_log() {
    local level="$1" color="$2"; shift 2
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$LOG_DIR"
    echo -e "${_DIM}${ts}${_NC} ${color}[${level}]${_NC} $*"
    echo "${ts} [${level}] $*" >> "$LOG_FILE"
}

log_info()    { _log "INFO " "$_CYAN"   "$@"; }
log_ok()      { _log "OK   " "$_GREEN"  "$@"; }
log_warn()    { _log "WARN " "$_YELLOW" "$@"; }
log_error()   { _log "ERROR" "$_RED"    "$@"; }
log_section() { _log "─────" "$_DIM" "── $* ──"; }
log_fatal()   { log_error "$@"; exit 1; }
```

---

## `lib/env.sh`

**Purpose:** Load and validate the `.env` file.  
**Depends on:** `lib/log.sh` must be sourced first.  
**How to test:** `source lib/log.sh && source lib/env.sh && load_env .env && echo $DEVICE_ID`

```bash
#!/bin/bash
[ -n "${_ENV_SH_LOADED:-}" ] && return 0
_ENV_SH_LOADED=1

load_env() {
    local env_file="${1:-$SCRIPT_DIR/.env}"
    [ -f "$env_file" ] || log_fatal ".env not found at $env_file"
    log_info "Loading environment from $env_file"
    set -o allexport
    # shellcheck source=/dev/null
    source "$env_file"
    set +o allexport
    log_ok "Environment loaded."
}

# Usage: require_vars VAR1 VAR2 ...
require_vars() {
    local missing=0
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            log_error "Required variable not set: $var"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || log_fatal "Fix missing variables in .env"
}

apply_defaults() {
    : "${FLASK_PORT:=5000}"
    : "${DISPLAY_MODE:=auto}"
    : "${IMAGE_DIR:=$SCRIPT_DIR/data/images}"
    : "${LOG_DIR:=/tmp/logs}"           # RAM — no SD card wear
    : "${CAPTURE_WIDTH:=1920}"
    : "${CAPTURE_HEIGHT:=1080}"
    : "${CAPTURE_QUALITY:=90}"
    : "${CAMERA_WARMUP_MS:=2000}"
    : "${CAPTURE_DELAY_MS:=500}"
    : "${HEARTBEAT_INTERVAL_SECONDS:=60}"
    : "${UPLOAD_TIMEOUT_SECONDS:=30}"
    : "${TRAINING_MODE:=false}"
}
```

---

## `lib/lock.sh`

**Purpose:** Prevent two instances of edge-client running simultaneously.  
**How to test:** Run `startup.sh &` then run it again — second should exit with a warning.

```bash
#!/bin/bash
[ -n "${_LOCK_SH_LOADED:-}" ] && return 0
_LOCK_SH_LOADED=1

LOCK_FILE="${LOCK_FILE:-/tmp/edge-client.lock}"

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_warn "Already running (PID $pid). Exiting."
            exit 0
        else
            log_warn "Stale lock (PID $pid). Removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_ok "Lock acquired (PID $$)."
}

release_lock() {
    rm -f "$LOCK_FILE"
    log_info "Lock released."
}
```

---

## `lib/display.sh`

**Purpose:** Detect display, detect touchscreen, launch Electron kiosk.  
**What changed:** `launch_kiosk()` now calls `electron` instead of `chromium-browser`. All Chromium-specific flags are gone. Electron handles fullscreen/kiosk internally via `main.js`.  
**How to test:** Call `launch_kiosk 5000` after Flask is running — Electron window should open fullscreen.

```bash
#!/bin/bash
[ -n "${_DISPLAY_SH_LOADED:-}" ] && return 0
_DISPLAY_SH_LOADED=1

display_is_available() {
    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

ensure_display() {
    if display_is_available; then
        log_ok "Display available: ${DISPLAY:-$WAYLAND_DISPLAY}"
        return 0
    fi
    if command -v startx &>/dev/null; then
        log_warn "No display — attempting startx on :0"
        export DISPLAY=:0
        startx -- :0 -nocursor &
        sleep 3
        display_is_available && log_ok "X started on :0" && return 0
    fi
    log_warn "No display. Running headless."
    return 1
}

detect_display_mode() {
    [ "${DISPLAY_MODE:-auto}" != "auto" ] && echo "$DISPLAY_MODE" && return
    xinput list 2>/dev/null | grep -qi "touch" && echo "touchscreen" || echo "desktop"
}

launch_kiosk() {
    local port="${1:-5000}"
    local mode; mode=$(detect_display_mode)
    local electron_dir; electron_dir="$(dirname "${BASH_SOURCE[0]}")/../electron"

    log_info "Launching Electron kiosk: mode=$mode port=$port"

    export DISPLAY="${DISPLAY:-:0}"
    xset s off 2>/dev/null || true
    xset -dpms 2>/dev/null || true
    xset s noblank 2>/dev/null || true

    # Pass config to Electron via env vars — main.js reads these
    export GRAINSCAN_FLASK_PORT="$port"
    export GRAINSCAN_DISPLAY_MODE="$mode"
    export GRAINSCAN_DEV="${ELECTRON_DEV:-false}"

    # --no-sandbox required on Pi (running as non-root without kernel namespaces)
    npx electron "$electron_dir" --no-sandbox \
        >> "${LOG_DIR:-/tmp}/electron.log" 2>&1 &

    log_ok "Electron launched (PID $!)."
}
```

---

## `lib/services.sh`

**Purpose:** Start Python services in background, health-check Flask, supervisor loop.  
**Critical:** `SERVICE_PIDS` is an associative array — requires bash 4+. Raspberry Pi OS ships bash 5, so this is fine.

```bash
#!/bin/bash
[ -n "${_SERVICES_SH_LOADED:-}" ] && return 0
_SERVICES_SH_LOADED=1

declare -A SERVICE_PIDS

wait_for_flask() {
    local port="${1:-5000}" retries="${2:-20}"
    log_info "Waiting for Flask on port $port..."
    local i=0
    while [ "$i" -lt "$retries" ]; do
        curl -sf "http://localhost:${port}/health" > /dev/null 2>&1 && log_ok "Flask ready." && return 0
        sleep 1; i=$((i+1))
    done
    log_fatal "Flask did not start within ${retries}s. Check ${LOG_DIR}/flask.log"
}

start_service() {
    local name="$1" script="$2"; shift 2
    local log_file="${LOG_DIR:-/tmp}/${name}.log"
    log_info "Starting service: $name"
    python3 "$script" "$@" >> "$log_file" 2>&1 &
    SERVICE_PIDS["$name"]=$!
    log_ok "$name started (PID ${SERVICE_PIDS[$name]}) → $log_file"
}

service_alive() {
    local pid="${SERVICE_PIDS[$1]:-}"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

supervise_flask() {
    local port="${FLASK_PORT:-5000}" script="${APP_DIR}/app.py"
    log_info "Supervisor loop started."
    while true; do
        if ! service_alive "flask"; then
            log_warn "Flask down. Restarting..."
            start_service "flask" "$script" --port "$port" --image-dir "$IMAGE_DIR"
            sleep 3
        fi
        sleep 10
    done
}

shutdown_all() {
    log_warn "Shutdown — stopping all services..."
    for name in "${!SERVICE_PIDS[@]}"; do
        local pid="${SERVICE_PIDS[$name]}"
        kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null && log_info "Stopped $name (PID $pid)"
    done
}
```

---

## `startup.sh`

**Purpose:** Boot orchestrator. Sources lib files, calls their functions in order. Contains no logic.

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
APP_DIR="$SCRIPT_DIR/src"
export LOG_DIR="$SCRIPT_DIR/data/logs"
export LOG_FILE="$LOG_DIR/startup.log"
export IMAGE_DIR="$SCRIPT_DIR/data/images"

mkdir -p "$LOG_DIR" "$IMAGE_DIR"

source "$LIB_DIR/log.sh"
source "$LIB_DIR/env.sh"
source "$LIB_DIR/lock.sh"
source "$LIB_DIR/display.sh"
source "$LIB_DIR/services.sh"

log_section "Lock"
acquire_lock
trap 'release_lock; shutdown_all' EXIT INT TERM

log_section "Environment"
load_env "$SCRIPT_DIR/.env"
require_vars DEVICE_ID API_BASE_URL MQTT_HOST MQTT_PORT
apply_defaults

log_section "Flask"
start_service "flask" "$APP_DIR/app.py" --port "$FLASK_PORT" --image-dir "$IMAGE_DIR"
wait_for_flask "$FLASK_PORT"

log_section "Uploader"
start_service "uploader" "$APP_DIR/uploader.py"

log_section "MQTT Agent"
start_service "mqtt-agent" "$APP_DIR/mqtt_agent.py"

log_section "Kiosk"
if ensure_display; then
    launch_kiosk "$FLASK_PORT"
else
    log_warn "No display — headless mode."
fi

log_section "Supervisor"
supervise_flask
```

---

## `scripts/capture.sh`

**Purpose:** Dual camera capture. Two shots, JSON to stdout. Called by `app.py` via subprocess.  
**Interface:**

- Args: `<device_id> <session_id> <output_dir>`
- Stdout: JSON `{"raw":"...", "ir":"...", "session_id":"...", "device_id":"...", "captured_at":"..."}`
- Exit 0 = success, Exit 2 = camera error, Exit 3 = file not written

**How to test standalone:**

```bash
bash scripts/capture.sh pi-001 test-abc-123 /tmp/test-images
```

```bash
#!/bin/bash
set -euo pipefail

DEVICE_ID="${1:?Usage: capture.sh <device_id> <session_id> <output_dir>}"
SESSION_ID="${2:?session_id required}"
OUTPUT_DIR="${3:?output_dir required}"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
RAW_PATH="${OUTPUT_DIR}/${DEVICE_ID}_${SESSION_ID}_${TIMESTAMP}_raw.jpg"
IR_PATH="${OUTPUT_DIR}/${DEVICE_ID}_${SESSION_ID}_${TIMESTAMP}_ir.jpg"

RESOLUTION_W="${CAPTURE_WIDTH:-1920}"
RESOLUTION_H="${CAPTURE_HEIGHT:-1080}"
WARMUP_MS="${CAMERA_WARMUP_MS:-2000}"
DELAY_MS="${CAPTURE_DELAY_MS:-500}"

LOG_FILE="${LOG_DIR:-/tmp}/capture.log"
mkdir -p "$OUTPUT_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [CAPTURE] $*" >> "$LOG_FILE"; }

# ── Take 1: NoIR raw ──────────────────────────────────────────────────────
log "Take 1 (raw) — session: $SESSION_ID"

python3 - <<PYEOF
import sys, os
try:
    from picamera2 import Picamera2
    import time
    cam = Picamera2()
    cam.configure(cam.create_still_configuration(
        main={"size": ($RESOLUTION_W, $RESOLUTION_H), "format": "RGB888"}
    ))
    cam.start()
    time.sleep($WARMUP_MS / 1000.0)
    cam.capture_file("$RAW_PATH")
    cam.stop(); cam.close()
except Exception as e:
    print(f"TAKE1_FAIL: {e}", file=sys.stderr)
    sys.exit(2)
PYEOF

[ -f "$RAW_PATH" ] || { log "ERROR: raw image not created"; exit 3; }
log "Take 1 OK → $RAW_PATH"

sleep "$(echo "scale=3; $DELAY_MS / 1000" | bc)"

# ── Take 2: NoIR + IR-pass filter ────────────────────────────────────────
# NOTE: If IR filter is physical clip-on — it must already be in position.
# If IR filter is GPIO-controlled, add GPIO trigger here before capture.
log "Take 2 (IR) — session: $SESSION_ID"

python3 - <<PYEOF
import sys, os
try:
    from picamera2 import Picamera2
    import time
    cam = Picamera2()
    cam.configure(cam.create_still_configuration(
        main={"size": ($RESOLUTION_W, $RESOLUTION_H), "format": "RGB888"}
    ))
    # Disable AWB — IR filter blocks visible light so AWB would distort the reading
    cam.set_controls({
        "AwbEnable": False,
        "ColourGains": (1.0, 1.0),
        "ExposureTime": int(os.environ.get("IR_EXPOSURE_US", "30000")),
    })
    cam.start()
    time.sleep($WARMUP_MS / 1000.0)
    cam.capture_file("$IR_PATH")
    cam.stop(); cam.close()
except Exception as e:
    print(f"TAKE2_FAIL: {e}", file=sys.stderr)
    sys.exit(2)
PYEOF

if [ ! -f "$IR_PATH" ]; then
    log "ERROR: IR image not created — deleting raw too"
    rm -f "$RAW_PATH"   # never send an incomplete pair
    exit 3
fi
log "Take 2 OK → $IR_PATH"

# ── Output JSON to stdout (read by app.py) ────────────────────────────────
cat <<JSON
{"raw":"$RAW_PATH","ir":"$IR_PATH","session_id":"$SESSION_ID","device_id":"$DEVICE_ID","captured_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}
JSON

log "Capture complete. Session: $SESSION_ID"
exit 0
```

---

## `src/app.py`

**Purpose:** Flask server running on `localhost:5000`. Serves kiosk HTML. Handles capture trigger.  
**Start command:** `python3 src/app.py --port 5000 --image-dir ./data/images`

### Routes

| Method | Path                    | What it does                                                |
| ------ | ----------------------- | ----------------------------------------------------------- |
| GET    | `/`                     | Serve kiosk HTML (mode select → WiFi → capture screens)     |
| GET    | `/health`               | `{"status":"ok"}` — polled by startup.sh                    |
| GET    | `/status`               | `{"wifi_connected":bool, "ssid":"...", "queue_depth":N}`    |
| GET    | `/wifi/scan`            | Run `nmcli`, return list of SSIDs + signal + security       |
| POST   | `/wifi/connect`         | Run `nmcli dev wifi connect {ssid} password {pw}`           |
| POST   | `/capture`              | Call `capture.sh`, hand off to uploader, return immediately |
| GET    | `/thumbnail/<filename>` | Serve a downscaled JPEG thumbnail for UI preview            |

### `/capture` route — exact behavior (non-blocking upload)

The UI must not wait for the cloud upload. Flask hands off to uploader and returns immediately.

```
1.  Read is_training flag from request body (default false)
2.  Generate UUID session_id
3.  subprocess.run(["bash", "scripts/capture.sh", DEVICE_ID, session_id, IMAGE_DIR], timeout=30)
4.  If returncode != 0: return 500 {"success":false, "error":"..."}
5.  Parse stdout JSON → get raw_path + ir_path
6.  Generate two low-res thumbnails (max 400px wide) → save to /tmp/thumbs/
7.  Return 200 IMMEDIATELY:
      {"success":true, "session_id":"...", "captured_at":"...",
       "thumb_raw":"/thumbnail/raw.jpg", "thumb_ir":"/thumbnail/ir.jpg"}
8.  [Background] Pass job to uploader.py via a shared in-memory queue (queue.Queue)
    uploader picks it up, POSTs to api-server, deletes local files on success
```

Why return immediately in step 7: The UI shows thumbnails the moment capture finishes. The researcher inspects them. While they're looking, the upload is already in flight. By the time they decide "looks good", it's usually already sent.

### UI flow — capture screen

The capture screen has **one state machine**. States:

```
READY
  └── researcher taps "Start Scan"
        ↓
CAPTURING
  └── spinner + "Take 1 of 2..." → "Take 2 of 2..."
  └── if capture fails → ERROR state (show message, tap to retry)
        ↓
REVIEWING
  └── show thumb_raw and thumb_ir side by side
  └── show session ID short code (first 8 chars) as a "receipt"
  └── show "Uploading..." spinner (non-blocking — upload is already happening)
  └── training mode badge visible if active
        ↓ (auto after 3 seconds, or researcher taps "Next")
READY
```

No confirmation dialog. No "Are you sure?". Researchers do many scans — the flow must be frictionless.

### Training mode toggle

Add a persistent toggle to the capture screen header:

```html
<label class="toggle">
  <input type="checkbox" id="training-toggle" />
  <span>Training mode</span>
</label>
```

When checked, the UI sends `{"is_training": true}` in the POST `/capture` body. The capture screen shows a visible badge ("TRAINING") so the researcher knows which mode they're in. The flag passes through to the api-server metadata — the api-server routes training images to a separate Supabase bucket and skips inference.

The toggle state persists in JavaScript memory for the session. It resets to `false` on page reload (intentional — training mode should be an explicit opt-in each time).

### `/thumbnail/<filename>` route

Generate thumbnails in the capture route, serve them here:

```python
from PIL import Image

def make_thumbnail(src_path, dest_path, max_width=400):
    img = Image.open(src_path)
    ratio = max_width / img.width
    new_size = (max_width, int(img.height * ratio))
    img.thumbnail(new_size, Image.LANCZOS)
    img.save(dest_path, "JPEG", quality=70)
```

Thumbnails go to `/tmp/thumbs/` — RAM, auto-cleaned on reboot.

### Python dependencies

Install on Pi:

```bash
pip3 install --break-system-packages flask requests python-jose loguru python-dotenv pillow
```

`picamera2` is installed via apt:

```bash
sudo apt install python3-picamera2
```

---

## `src/uploader.py`

**Purpose:** Background process. Receives jobs from `app.py` via a shared `queue.Queue`. Sends to api-server. Refreshes JWT.  
**Start command:** `python3 src/uploader.py`

### How app.py hands off a job (non-blocking)

`app.py` and `uploader.py` share an in-process queue when run together under startup.sh. `app.py` puts a job on the queue and returns immediately to the UI. `uploader.py` pulls from the queue in its own thread.

```python
# shared between app.py and uploader.py (imported from a shared module)
upload_queue = queue.Queue()

# app.py — after capture.sh succeeds:
upload_queue.put({
    "session_id": session_id,
    "raw_path":   raw_path,
    "ir_path":    ir_path,
    "captured_at": captured_at,
    "label":      label,
    "is_training": is_training,
})
# returns 200 to UI immediately — does not wait for upload

# uploader.py — worker thread:
while True:
    job = upload_queue.get()   # blocks until a job arrives
    ensure_valid_jwt()
    post_to_ingest(job)        # multipart POST
    upload_queue.task_done()
```

### JWT refresh logic

```python
def ensure_valid_jwt():
    if jwt_expires_in_seconds() > 300:
        return   # still good
    response = requests.post(f"{API_BASE_URL}/api/v1/auth/device-token", json={
        "device_id": DEVICE_ID,
        "signature": hmac_sign(DEVICE_SECRET, timestamp)
    })
    store_jwt(response.json()["access_token"])
```

---

## `src/heartbeat.py`

**Purpose:** Pings api-server every 60 seconds so the dashboard can show device online/offline.  
**Start command:** `python3 src/heartbeat.py`

```python
while True:
    try:
        requests.post(
            f"{API_BASE_URL}/api/v1/devices/{DEVICE_ID}/heartbeat",
            json={
                "timestamp": datetime.utcnow().isoformat(),
                "disk_free_mb": shutil.disk_usage("/").free // (1024*1024),
            },
            headers={"Authorization": f"Bearer {get_jwt()}"},
            timeout=10
        )
    except Exception:
        pass   # heartbeat failure is non-fatal, try again next cycle
    time.sleep(int(os.getenv("HEARTBEAT_INTERVAL_SECONDS", 60)))
```

---

## `electron/` — The UI Layer

Electron replaces Chromium kiosk. The renderer is just HTML/CSS/JS making `fetch()` calls to Flask on `localhost:5000` — the same API contract as before. Nothing in `src/` changes.

### Why Electron over Chromium kiosk

|                          | Chromium `--kiosk`         | Electron                                           |
| ------------------------ | -------------------------- | -------------------------------------------------- |
| Dev experience           | Edit HTML, refresh browser | Hot reload, DevTools, familiar workflow            |
| Native APIs              | No                         | `ipcMain/ipcRenderer`, `shell`, `dialog`           |
| Dev vs Pi mode           | Same flags everywhere      | `ELECTRON_DEV=true` opens DevTools, disables kiosk |
| Build once, run anywhere | Pi only                    | Develop on laptop, deploy to Pi                    |
| Future GPIO              | Needs Python subprocess    | Can use `node-addon-api` if needed                 |

### `electron/package.json`

```json
{
  "name": "grainscan-kiosk",
  "version": "1.0.0",
  "description": "GrainScan Pi kiosk UI",
  "main": "main.js",
  "scripts": {
    "start": "electron . --no-sandbox",
    "dev": "ELECTRON_DEV=true electron . --no-sandbox"
  },
  "dependencies": {
    "electron": "^29.0.0"
  }
}
```

Install on Pi:

```bash
cd electron
npm install
```

> Electron 29+ supports `linux-arm64` (Pi 4/5) natively. `npm install` pulls the correct binary automatically.

---

### `electron/main.js`

This is the Node.js process. It creates the window, sets kiosk mode, waits for Flask to be ready, then loads the UI.

```javascript
const { app, BrowserWindow, ipcMain, shell } = require("electron");
const path = require("path");
const http = require("http");

// ── Config from env (set by lib/display.sh) ───────────────────────────────
const FLASK_PORT = process.env.GRAINSCAN_FLASK_PORT || "5000";
const DEV_MODE = process.env.GRAINSCAN_DEV === "true";
const DISPLAY_MODE = process.env.GRAINSCAN_DISPLAY_MODE || "auto";
const FLASK_URL = `http://localhost:${FLASK_PORT}`;

let win;

// ── Wait for Flask to be ready before loading UI ──────────────────────────
function waitForFlask(retries = 30) {
  return new Promise((resolve, reject) => {
    let attempts = 0;

    const check = () => {
      http
        .get(`${FLASK_URL}/health`, (res) => {
          if (res.statusCode === 200) return resolve();
          retry();
        })
        .on("error", retry);
    };

    const retry = () => {
      attempts++;
      if (attempts >= retries) return reject(new Error("Flask did not start"));
      setTimeout(check, 1000);
    };

    check();
  });
}

// ── Create the BrowserWindow ──────────────────────────────────────────────
function createWindow() {
  win = new BrowserWindow({
    // Kiosk on Pi, windowed on laptop for dev
    kiosk: !DEV_MODE,
    fullscreen: !DEV_MODE,
    frame: DEV_MODE, // title bar visible only in dev
    resizable: DEV_MODE,

    // Touch-friendly defaults
    width: 1280,
    height: 800,

    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true, // security: renderer can't access Node directly
      nodeIntegration: false, // security: no require() in renderer
    },
  });

  // Open DevTools in dev mode
  if (DEV_MODE) win.webContents.openDevTools({ mode: "detach" });

  // Load the UI — passes mode to renderer via URL query param
  win.loadURL(`${FLASK_URL}/?mode=${DISPLAY_MODE}`);

  // Prevent renderer from navigating away from localhost
  win.webContents.on("will-navigate", (event, url) => {
    if (!url.startsWith(FLASK_URL)) {
      event.preventDefault();
      shell.openExternal(url); // open external links in system browser
    }
  });
}

// ── App lifecycle ─────────────────────────────────────────────────────────
app.whenReady().then(async () => {
  try {
    await waitForFlask();
    createWindow();
  } catch (err) {
    console.error("Flask never became ready:", err.message);
    app.quit();
  }
});

app.on("window-all-closed", () => app.quit());

// ── IPC handlers (main process side) ─────────────────────────────────────
// These are optional — the renderer can call Flask directly via fetch().
// Add ipcMain handlers here only for things that need Node.js access
// (file system, native dialogs, GPIO via child_process, etc.)

// Example: renderer asks main to reveal a file in Finder/Files
ipcMain.handle("show-item", (_, filePath) => {
  shell.showItemInFolder(filePath);
});
```

---

### `electron/preload.js`

The bridge between the sandboxed renderer and the main process. Expose only what the renderer needs.

```javascript
const { contextBridge, ipcRenderer } = require("electron");

// Everything exposed here is available in the renderer as window.electronAPI
contextBridge.exposeInMainWorld("electronAPI", {
  // Pass display mode so renderer can set CSS class immediately
  displayMode: process.env.GRAINSCAN_DISPLAY_MODE || "auto",

  // Is this a dev session?
  isDev: process.env.GRAINSCAN_DEV === "true",

  // Future: expose any ipcMain handlers you add
  // showItem: (filePath) => ipcRenderer.invoke('show-item', filePath),
});
```

---

### `electron/renderer/index.html`

The renderer still talks to Flask via `fetch()` — identical to what was in `app.py`'s inline HTML before. The only difference is that `window.electronAPI` is now available for Electron-native features.

Minimal structure:

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <!-- CSP: only allow requests to localhost -->
    <meta
      http-equiv="Content-Security-Policy"
      content="default-src 'self'; connect-src http://localhost:*; script-src 'self'; style-src 'self' 'unsafe-inline'"
    />
    <title>GrainScan</title>
    <link rel="stylesheet" href="styles.css" />
  </head>
  <body>
    <!-- Screen 1: mode select -->
    <div id="screen-mode" class="screen active">...</div>

    <!-- Screen 2: WiFi -->
    <div id="screen-wifi" class="screen">...</div>

    <!-- Screen 3: Capture (READY / CAPTURING / REVIEWING states) -->
    <div id="screen-capture" class="screen">...</div>

    <script src="index.js"></script>
  </body>
</html>
```

**Important:** Because Electron loads `renderer/index.html` as a local file (`file://`), the `fetch()` calls to Flask must use absolute URLs:

```javascript
// index.js — always use the full URL, not relative paths
const FLASK = "http://localhost:5000";

async function triggerCapture(label, isTraining) {
  const res = await fetch(`${FLASK}/capture`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ label, is_training: isTraining }),
  });
  return res.json();
}
```

Wait — `main.js` above uses `win.loadURL(FLASK_URL)` which loads the Flask-served HTML directly. This is actually simpler: the renderer IS the Flask page, already served over HTTP so relative `fetch()` paths work. You can switch to `win.loadFile('renderer/index.html')` later if you want to fully separate the UI from Flask, but `loadURL` is the easier starting point.

---

### Dev workflow on your laptop

```bash
# Terminal 1 — start Flask (mock camera returns dummy images)
cd edge-client
python3 src/app.py --port 5000 --image-dir /tmp/imgs

# Terminal 2 — start Electron in dev mode
cd electron
ELECTRON_DEV=true GRAINSCAN_FLASK_PORT=5000 npm start
```

Electron opens a normal window with DevTools. You edit `renderer/index.html` or `index.js`, reload with `Cmd+R`. When it looks good, `git push` → Ansible deploys to Pi.

### Deploy to Pi

`provision.sh` installs Node.js 20 LTS and runs `npm install` in the `electron/` directory. No build step needed — Electron runs from source on the Pi.

```bash
# provision.sh additions (add to the existing script):
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
cd /home/grainbot/edge-client/electron && npm install
```

---

## API Server Contract (what edge-client sends)

The edge-client only knows about these three endpoints. All are on `API_BASE_URL`.

### `POST /api/v1/auth/device-token`

```
Body (JSON):
  device_id: string
  signature: base64(HMAC-SHA256(device_secret, timestamp_utc_iso))
  timestamp: ISO8601 UTC string (server validates within ±5 min)

Response 200:
  access_token: string (JWT, 1 hour)
  expires_in: 3600
```

### `POST /api/v1/ingest`

```
Content-Type: multipart/form-data
Authorization: Bearer {jwt}

Fields:
  image_raw: File (JPEG)
  image_ir:  File (JPEG)
  metadata:  JSON string {
    "device_id":   "pi-001",
    "session_id":  "uuid-v4",
    "captured_at": "2026-03-15T10:00:00Z",
    "label":       "Plot A Row 3",   (optional)
    "is_training": false             (true = route to training bucket, skip inference)
  }

Response 201:
  task_id: string
  status:  "queued"

Response 401: JWT invalid or expired
Response 429: Rate limit hit
```

### `POST /api/v1/devices/{device_id}/heartbeat`

```
Authorization: Bearer {jwt}
Body (JSON):
  timestamp:    ISO8601 UTC
  disk_free_mb: integer

Response 200:
  received: true
```

---

## Systemd Service File

Path: `/etc/systemd/system/edge-client.service`

```ini
[Unit]
Description=GrainScan Edge Client
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=simple
User=grainbot
Group=grainbot
WorkingDirectory=/home/grainbot/edge-client

ExecStartPre=/bin/bash -c "age -d -i /home/grainbot/.keys/grainbot.key \
  -o /home/grainbot/edge-client/.env \
  /home/grainbot/edge-client/.env.age"

ExecStart=/bin/bash /home/grainbot/edge-client/startup.sh

Restart=on-failure
RestartSec=10
# Logs go to RAM (/tmp) — zero SD card wear. Viewable during current session via SSH.
StandardOutput=append:/tmp/logs/systemd.log
StandardError=append:/tmp/logs/systemd.log

Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/grainbot/.Xauthority
Environment=LOG_DIR=/tmp/logs
# Node.js must be in PATH for `npx electron` to work
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/grainbot/.npm-global/bin

[Install]
WantedBy=graphical.target
```

---

## IR Filter — Hardware Decision (OPEN — must resolve before capture.sh is final)

`capture.sh` has a placeholder between Take 1 and Take 2. What goes there depends entirely on your hardware. Pick one:

### Option A — Physical clip-on filter (researcher swaps manually)

No GPIO needed. The researcher clips the IR-pass filter onto the lens before starting a scan, and leaves it there. Both shots use the filter. Take 1 has AWB on, Take 2 has AWB off. The difference between the two images comes from the camera settings, not the filter position.

```bash
# Between Take 1 and Take 2 in capture.sh — nothing. No GPIO.
sleep "$(echo "scale=3; $DELAY_MS / 1000" | bc)"
```

Simplest. Requires researcher discipline. Works fine for a controlled lab environment.

### Option B — GPIO-controlled filter wheel or servo

A motor physically moves the filter in front of the lens between shots. You need the `gpiod` tools.

```bash
# Between Take 1 and Take 2:
gpioset gpiochip0 17=1        # energize servo/motor — moves filter into position
sleep 0.5                     # wait for filter to physically settle
# ... Take 2 capture ...
gpioset gpiochip0 17=0        # retract filter after shot
```

GPIO pin number (17 above) depends on your wiring. Add `GPIO_FILTER_PIN` to `.env`.

### Option C — LED switching (no physical filter)

The "IR filter" is actually just two sets of LEDs — white LEDs for Take 1, IR LEDs for Take 2. No moving parts.

```bash
# Before Take 1:
gpioset gpiochip0 17=1   # white LEDs on
gpioset gpiochip0 18=0   # IR LEDs off
# ... Take 1 ...

# Before Take 2:
gpioset gpiochip0 17=0   # white LEDs off
gpioset gpiochip0 18=1   # IR LEDs on
sleep 0.2                # LEDs need ~200ms to stabilise
# ... Take 2 ...

# After Take 2:
gpioset gpiochip0 18=0   # IR LEDs off
```

Add `GPIO_WHITE_LED_PIN` and `GPIO_IR_LED_PIN` to `.env`. Install: `sudo apt install gpiod`.

**Until you decide:** The current `capture.sh` has a comment placeholder. Do not remove it — it marks exactly where the GPIO logic goes.

---

## Testing Checklist — Before Deploying to Pi

Work through this in order. Each item can be tested in isolation before the next.

### Shell layer (test on any Linux machine, not just Pi)

- [ ] `source lib/log.sh && log_info "test"` — colors appear, file written to `/tmp/logs/startup.log`
- [ ] `source lib/log.sh && source lib/env.sh && load_env .env` — vars exported to shell
- [ ] `require_vars MISSING_VAR` — exits with error message
- [ ] Run `startup.sh` twice simultaneously — second instance exits with "Already running"
- [ ] Reboot Pi — confirm `/tmp/logs/` is empty (RAM wipe confirmed)

### Camera (Pi only)

- [ ] `bash scripts/capture.sh pi-dev test-001 /tmp/imgs` — two files appear in `/tmp/imgs`
- [ ] Output is valid JSON: `bash scripts/capture.sh pi-dev test-002 /tmp/imgs | python3 -m json.tool`
- [ ] Disconnect camera mid-capture — script exits non-zero, no orphan files

### Flask (Pi or laptop with mock camera)

- [ ] `python3 src/app.py --port 5000 --image-dir /tmp/imgs`
- [ ] `curl localhost:5000/health` → `{"status":"ok"}`
- [ ] `curl localhost:5000/wifi/scan` → list of networks
- [ ] Open `http://localhost:5000` in browser — three screens work

### Electron (laptop first, then Pi)

- [ ] `cd electron && npm install` — no errors, `node_modules/electron` present
- [ ] `ELECTRON_DEV=true GRAINSCAN_FLASK_PORT=5000 npm start` — window opens, DevTools visible
- [ ] `fetch('http://localhost:5000/health')` in DevTools console → `{status:"ok"}`
- [ ] Mode select buttons work, WiFi screen loads, capture screen loads
- [ ] On Pi: `npm start` from `electron/` (after Flask running) — fullscreen kiosk, no frame, no escape

### Full boot (Pi only)

- [ ] `sudo systemctl start edge-client` — Electron window appears within 30s
- [ ] Connect WiFi through kiosk UI
- [ ] Tap capture — REVIEWING state shows two thumbnails
- [ ] Session ID short code visible on success screen
- [ ] After 3 seconds — auto-resets to READY
- [ ] Enable training mode toggle — badge appears, `is_training:true` in Supabase `scans` row
- [ ] Images appear in Supabase Storage (correct bucket: inference vs training)
- [ ] `sudo systemctl stop edge-client` — lock file removed, no orphan processes
- [ ] Pull power, reboot — everything comes back cleanly, `/tmp/logs` empty

---

## Common Issues and Fixes

| Issue                                  | Likely cause                                   | Fix                                                                                |
| -------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------- |
| Flask doesn't start                    | Missing Python package                         | `pip3 install flask --break-system-packages`                                       |
| picamera2 import error                 | Not using Pi or wrong Python                   | `sudo apt install python3-picamera2`                                               |
| Electron window doesn't open           | Node not in PATH in systemd                    | Add `Environment=PATH=...` to service file (see above)                             |
| Electron opens then immediately closes | Flask not ready when Electron launched         | `waitForFlask()` in `main.js` retries 30× — check Flask log first                  |
| Black screen in kiosk                  | Display not ready before `startx` completes    | Increase `sleep 3` in `ensure_display()` to `sleep 5`                              |
| `--no-sandbox` error                   | Missing flag                                   | Always pass `--no-sandbox` on Pi (non-root, no kernel namespaces)                  |
| `npx electron` not found               | Node not installed or wrong PATH               | `curl -fsSL https://deb.nodesource.com/setup_20.x \| bash - && apt install nodejs` |
| `fetch()` returns CORS error           | Renderer loaded as `file://` with relative URL | Use absolute URLs: `http://localhost:5000/capture` not `/capture`                  |
| `age` decrypt fails                    | Key not at `~/.keys/grainbot.key`              | Check path in systemd `ExecStartPre`                                               |
| WiFi scan returns empty                | `nmcli` not installed                          | `sudo apt install network-manager`                                                 |
| Camera warmup too short                | Auto-exposure not settling                     | Increase `CAMERA_WARMUP_MS` in `.env`                                              |
| IR shot overexposed                    | Exposure time too high                         | Lower `IR_EXPOSURE_US` in `.env` (default 30000 = 30ms)                            |
| Thumbnail not showing                  | Pillow not installed                           | `pip3 install pillow --break-system-packages`                                      |
| GPIO filter not moving                 | Wrong pin or gpiod not installed               | `sudo apt install gpiod`, check pin number in `.env`                               |
| Training images going to wrong bucket  | `is_training` flag not reaching api-server     | Check toggle state in DevTools console, verify metadata JSON                       |
| Logs missing after reboot              | Expected — `/tmp` is RAM                       | SSH in during session, or temporarily set `LOG_DIR=./data/logs`                    |
