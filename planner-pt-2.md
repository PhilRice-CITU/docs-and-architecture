# GrainScan — Project Planner
**Project:** Rice grain classification system — PhilRice field deployment  
**Status:** Pre-development  
**Last updated:** 2026-03-15

---

## What we're building

Five repositories. One Pi per field site. Images go up, classifications come back, researchers see results on a dashboard.

```
edge-client  →  api-server  →  ai-vision-model
                    ↓
               Supabase
                    ↑
            web-dashboard
```

---

## Phase 0 — Foundation
**Goal:** Nothing breaks before you write a line of application code.  
**When:** Before touching any repo.

| # | Task | Repo | Done? |
|---|------|------|-------|
| 0.1 | Create Supabase project, get URL + anon key + service key | — | ☐ |
| 0.2 | Create Supabase tables: `devices`, `scans`, `results`, `heartbeats` | — | ☐ |
| 0.3 | Create Supabase Storage bucket: `scan-images` (private) | — | ☐ |
| 0.4 | Set up Row Level Security policies (device role: INSERT only, dashboard role: SELECT only) | — | ☐ |
| 0.5 | Create all five GitHub repos with branch protection on `main` | — | ☐ |
| 0.6 | Add `.env.example` files to each repo so contributors know what vars are needed | — | ☐ |
| 0.7 | Register a Tailscale account, install on your laptop | — | ☐ |

**Exit criteria:** Supabase is live, all repos exist, you can connect to Supabase from your laptop.

---

## Phase 1 — Edge Client
**Goal:** Pi boots → kiosk appears → researcher taps → two images land in Supabase Storage.  
**This is the first thing you test on real hardware.**

### 1A — Provisioning (do this first, on a fresh Pi)

| # | Task | File | Done? |
|---|------|------|-------|
| 1.1 | Flash Raspberry Pi OS Lite 64-bit to SD card | — | ☐ |
| 1.2 | Enable SSH on first boot (create empty `ssh` file in `/boot`) | — | ☐ |
| 1.3 | SCP your SSH public key to Pi | — | ☐ |
| 1.4 | Run `sudo bash provision.sh` — hardens OS, installs deps, creates `grainbot` user | `provision.sh` | ☐ |
| 1.5 | Register Pi with Tailscale: `sudo tailscale up` | — | ☐ |
| 1.6 | Generate `age` keypair on Pi, share public key | `provision.sh` output | ☐ |
| 1.7 | Create real `.env`, encrypt it: `age -r <pubkey> -o .env.age .env` | — | ☐ |
| 1.8 | Commit `.env.age`, confirm `.env` is in `.gitignore` | — | ☐ |

### 1B — Shell layer

| # | Task | File | Done? |
|---|------|------|-------|
| 1.9 | Write and test `lib/log.sh` in isolation: `source lib/log.sh && log_info "hello"` | `lib/log.sh` | ☐ |
| 1.10 | Write and test `lib/env.sh`: source it, confirm vars load correctly | `lib/env.sh` | ☐ |
| 1.11 | Write and test `lib/lock.sh`: run two instances, confirm second exits | `lib/lock.sh` | ☐ |
| 1.12 | Write and test `lib/display.sh`: confirm Chromium launches pointing to a test URL | `lib/display.sh` | ☐ |
| 1.13 | Write and test `lib/services.sh`: start a dummy Python script, confirm PID tracking | `lib/services.sh` | ☐ |
| 1.14 | Wire up `startup.sh` to call all lib functions in order | `startup.sh` | ☐ |
| 1.15 | Install systemd service, test `sudo systemctl start edge-client` | `provision.sh` | ☐ |

### 1C — Python layer

| # | Task | File | Done? |
|---|------|------|-------|
| 1.16 | Write `src/app.py` — Flask with `/health`, `/status`, `/wifi/scan`, `/wifi/connect`, `/capture` routes | `src/app.py` | ☐ |
| 1.17 | Write the kiosk HTML (three screens: mode select, WiFi, capture) served by Flask | `src/app.py` | ☐ |
| 1.18 | Test WiFi scan and connect from the kiosk UI manually | — | ☐ |
| 1.19 | Write `scripts/capture.sh` — two-shot NoIR capture, JSON stdout output | `scripts/capture.sh` | ☐ |
| 1.20 | Test capture standalone: `bash capture.sh pi-001 test-123 /tmp/images` | — | ☐ |
| 1.21 | Connect POST `/capture` in Flask to call `capture.sh` via subprocess | `src/app.py` | ☐ |
| 1.22 | Write `src/heartbeat.py` — 60s POST loop to api-server | `src/heartbeat.py` | ☐ |
| 1.23 | Write `src/uploader.py` — connectivity check + POST /ingest with JWT | `src/uploader.py` | ☐ |

### 1D — End-to-end smoke test

| # | Task | Done? |
|---|------|-------|
| 1.24 | Boot Pi cold, confirm kiosk appears within 30 seconds | ☐ |
| 1.25 | Connect to WiFi through kiosk UI | ☐ |
| 1.26 | Tap capture, confirm two image files appear in Supabase Storage | ☐ |
| 1.27 | Pull Pi power mid-capture, reboot, confirm no orphan files or errors | ☐ |
| 1.28 | Confirm heartbeat shows up in Supabase `heartbeats` table | ☐ |

**Exit criteria:** Researcher taps the button on a real Pi and two images land in Supabase Storage within 10 seconds.

---

## Phase 2 — API Server
**Goal:** Receives images from Pi, dispatches to model, writes results to Supabase.

| # | Task | File | Done? |
|---|------|------|-------|
| 2.1 | Scaffold FastAPI project, Dockerfile | `api-server/` | ☐ |
| 2.2 | `POST /api/v1/auth/device-token` — HMAC-validate device, return short-lived JWT | — | ☐ |
| 2.3 | `POST /api/v1/ingest` — validate JWT, receive multipart images, store to Supabase Storage | — | ☐ |
| 2.4 | `POST /api/v1/devices/{id}/heartbeat` — write to `heartbeats` table | — | ☐ |
| 2.5 | `GET /api/v1/health` — liveness check | — | ☐ |
| 2.6 | Dispatch job to `ai-vision-model` after ingest | — | ☐ |
| 2.7 | Write result to Supabase `results` table on model response | — | ☐ |
| 2.8 | Rate limiting per `device_id` | — | ☐ |
| 2.9 | Deploy to Railway / Fly.io / VPS, point `API_BASE_URL` in Pi `.env.age` | — | ☐ |

**Exit criteria:** Pi POST → Supabase Storage has images → `scans` row created → model called.

---

## Phase 3 — AI Vision Model
**Goal:** Receives two images, returns classification + confidence.

| # | Task | File | Done? |
|---|------|------|-------|
| 3.1 | Wrap existing model in a FastAPI inference service | `ai-vision-model/` | ☐ |
| 3.2 | `POST /predict` — accept `{task_id, image_raw_url, image_ir_url}`, return classification JSON | — | ☐ |
| 3.3 | Integration test with real images from Phase 1 | — | ☐ |
| 3.4 | Deploy as separate container (independent of api-server) | — | ☐ |

**Exit criteria:** `POST /predict` with real Pi images returns `{classification, confidence}` correctly.

---

## Phase 4 — Web Dashboard
**Goal:** Researcher at a desk sees device status and classification results in real time.

| # | Task | Done? |
|---|------|-------|
| 4.1 | Scaffold Next.js project, connect to Supabase JS client | ☐ |
| 4.2 | Device list page — online/offline status from latest heartbeat timestamp | ☐ |
| 4.3 | Scan history page — sorted by `captured_at`, filterable by device | ☐ |
| 4.4 | Result detail page — both images + classification + confidence score | ☐ |
| 4.5 | Realtime subscription on `results` table INSERT — new scan appears without refresh | ☐ |
| 4.6 | Label editing — researcher can edit the label on a scan (not the result) | ☐ |
| 4.7 | Accept / pending status — researcher can mark a result as accepted or leave pending | ☐ |

**Exit criteria:** Researcher sees a new classification appear within 5 seconds of Pi button tap.

---

## Phase 5 — Hardening
**Goal:** The system survives real field conditions.

| # | Task | Done? |
|---|------|-------|
| 5.1 | Ansible playbook tested on a second Pi from scratch | ☐ |
| 5.2 | Alert on missed heartbeat (>5 min) → email/SMS | ☐ |
| 5.3 | Log shipping from Pi to api-server (or Logflare) | ☐ |
| 5.4 | Load test: 10 simultaneous captures across 5 Pis | ☐ |
| 5.5 | Documented runbook: what to do when X fails | ☐ |

---

## Build Order — What to do right now

```
Today
  └── Phase 0 (all of it — takes ~1 hour)

This week
  └── Phase 1A (provision a Pi)
  └── Phase 1B (shell layer — test each lib file independently)

Next week
  └── Phase 1C (Python layer — Flask + capture.sh)
  └── Phase 1D (smoke test on real hardware)

After that
  └── Phase 2 (api-server) and Phase 3 (model) in parallel
  └── Phase 4 (dashboard) once Phase 2 is live
  └── Phase 5 (hardening) continuously
```

---

## Known Open Questions

| Question | Blocks |
|----------|--------|
| How does the IR filter attach? (clip-on manually by researcher, or GPIO-controlled?) | `capture.sh` — there's a sleep + optional GPIO trigger between the two shots |
| What is the capture trigger? (kiosk button only, or also GPIO button on the Pi enclosure?) | `src/app.py` — may need a GPIO background thread |
| Single account with multiple devices, or per-device login? | `web-dashboard` + Supabase auth design |
| What classification labels does the model output? (grain variety names?) | `results` table schema + dashboard display |
| Where does the api-server live? (Railway, Fly, your own VPS?) | Phase 2 deployment |