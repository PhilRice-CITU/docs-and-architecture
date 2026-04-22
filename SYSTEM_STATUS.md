# Rice Vision — System Status

**Last reviewed:** 2026-04-22  
**Reviewer:** Claude Code audit

This document is the single source of truth for the current implementation state of all four repositories. Update it whenever a bug is fixed or a feature is completed.

---

## Repository Status Overview

| Repo | Status | Summary |
|------|--------|---------|
| `ai-vision-model` | ✅ Functionally complete | Inference pipeline works end-to-end in stub mode; ONNX path ready |
| `api-server` | ⚠️ Functional but broken integration | Endpoints work; inference never called; metrics schema mismatch |
| `edge-client` | ⚠️ Works on laptop; Pi incomplete | Flask + Electron functional; heartbeat.py missing; no MQTT |
| `web-dashboard` | ⚠️ Partially wired | Real API client exists; some pages still use mock data |

---

## Current State by Repository

### `ai-vision-model` — ✅ Most Complete

**What works:**
- Full inference pipeline: stub mode (synthetic grains) + ONNX real-model path
- `python main.py --stub` works end-to-end with no model file present
- Feature extraction (`features.py`): per-grain length/width/size class via OpenCV
- Grader (`grader.py`): full PNS/BAFS 290:2025 Table 2 thresholds + brewer exception
- Report (`report.py`): result payload dict + Excel `.xlsx` export to `outputs/`
- `PX_PER_MM = 54.6539` calibrated from a 23mm Philippine peso coin

**What's incomplete:**
- `contrasting_types_pct` is hardcoded to `0.0` — needs variety metadata to compute
- The pipeline is never called by the API server (see Bug 1)

**Output format** (what report.py produces):
```json
{
  "grade": "Premium|Grade No. 1|...|Off-Grade",
  "limiting_factor": "chalky_kernels_pct",
  "grain_size_class": "long",
  "total_grains_detected": 112,
  "stub_mode": false,
  "parameters": {
    "broken_kernels_pct": 8.93,
    "chalky_kernels_pct": 6.25,
    "discolored_kernels_pct": 0.71,
    "foreign_matter_pct": 0.0,
    "brewers_pct": 0.18,
    "damaged_kernels_pct": 0.89,
    "immature_kernels_pct": 0.45,
    "red_kernels_pct": 1.79,
    "contrasting_types_pct": 0.0
  },
  "per_grain": [...]
}
```

---

### `api-server` — ⚠️ Functional but inference NOT wired

**What works:**
- FastAPI server on port 3001 with Supabase (PostgreSQL + Storage)
- `POST /scans` and `POST /scans/batch`: accepts images, uploads to Supabase Storage, inserts result row
- JWT auth via `get_current_user()`: admin (region-scoped) + superadmin (all regions)
- All CRUD routers: devices, results, regions, analytics, events, live, suggestions
- MQTT bridge class exists and is initialized in app lifespan

**What's broken (see Bugs 1–4, 6, 8 below):**
- `metrics` field is always `{}` — inference pipeline never runs after image upload
- Analytics queries field names that don't exist in the vision model output
- Grade format mismatch: vision model → `"Premium"`, analytics expects `"A"`
- `paho-mqtt` missing from environment → server startup crashes
- `/scans/batch` silently discards all but the last image pair
- `results.status` column (from migration 001) is never updated past `'pending'`

---

### `edge-client` — ⚠️ Works on Laptop, Pi Incomplete

**What works:**
- Flask API on port 5055: session CRUD, capture trigger, submit, webhook receiver
- `session_manager.py`: JSON-backed session state in `data/sessions/`
- `uploader.py`: queue-based async processor, polls `data/upload_queue.json` every 3s
- `upload_router.py`: routes to `POST /scans/batch` (production) or Roboflow (training)
- Electron kiosk UI: React 19 + TanStack Router + TanStack Query, Atomic Design components
- Hooks: `useDeviceStatus`, `useSession`, `useCapture` — all tested (39 Vitest tests)

**What's missing/broken (see Bugs 5, 7 below):**
- `heartbeat.py` does not exist — `startup.sh` references it but it was never implemented
- `POST /sessions/{id}/submit` allows double-submit (no status guard)
- No MQTT listener or sender on the edge — API has MQTT bridge but edge can't receive commands
- Camera capture (`rpicam-still`) only works on Pi hardware — expected on laptop

---

### `web-dashboard` — ⚠️ Partially Wired to Real API

**What works:**
- React 19 + Vite + TanStack Router + TanStack Query
- `src/api/client.ts`: real Axios client with Supabase JWT injection, 401 redirect
- `src/hooks/useApi.ts`: TanStack Query hooks (`useFetch`, `useCreate`, `useUpdate`, `useDelete`)
- Supabase auth flow (login, register, session persistence)
- 6 theme system (`src/lib/themes.ts`) — CSS variable injection via `ThemeProvider`

**What's incomplete:**
- `src/lib/mockData.ts` contains extensive mock devices, grain results, and analytics — unknown which pages use it vs the real API client
- Analytics page charts may still be driven by mock data since real `metrics` fields are all empty in the database
- OpenAPI types (`src/api/types/openapi.ts`) need to be regenerated once API is stable

---

## Confirmed Bugs

### 🔴 Critical

**BUG 1: Inference pipeline never runs on scan ingest**
- `POST /scans` uploads images and inserts `metrics: {}` — the `ai-vision-model` pipeline is never called
- Every result in the database has empty metrics → all analytics return zeros
- **File:** `api-server/app/routers/scans.py` lines 52–66

**BUG 2: Grade format mismatch — vision model vs analytics**
- Vision model outputs: `"Premium"`, `"Grade No. 1"` ... `"Grade No. 5"`, `"Off-Grade"`
- Analytics router expects: `"A"`, `"B"`, `"C"`, `"D"` (in `metrics.qualityGrade`)
- No mapping layer exists between the two
- **Files:** `api-server/app/routers/analytics.py` lines 33, 156–163, 369

**BUG 3: Analytics metrics field names don't match vision model output**
- Analytics reads: `qualityGrade`, `totalGrains`, `moistureContent`, `brokenGrains`, `foreignMatter`, `chalkinessPercentage`, `discolorationPercentage`, `grainLengthMm`, `qualityScore`
- Vision model outputs: `grade`, `total_grains_detected`, `parameters.broken_kernels_pct`, `parameters.chalky_kernels_pct`, `parameters.discolored_kernels_pct`, etc.
- Completely different field names — analytics returns zeros even if inference ran
- **Files:** `api-server/app/routers/analytics.py` lines 166–182; `ai-vision-model/inference/report.py`
- **Fix:** Define and implement the metrics contract — see `api-server/metrics-contract.md`

**BUG 4: `paho-mqtt` not installed → server won't start**
- `app/services/mqtt_bridge.py` imports `paho.mqtt.client` at module level
- Package missing from venv → `ModuleNotFoundError: No module named 'paho'` on startup
- **Fix:** `pip install -e ".[dev]"` (verify `paho-mqtt` is in `pyproject.toml` dependencies)

---

### 🟡 Medium

**BUG 5: `heartbeat.py` referenced but doesn't exist**
- `startup.sh` starts `src/heartbeat.py` as a background service
- File does not exist → Pi startup fails at that step
- **File:** `edge-client/startup.sh`; missing file: `edge-client/src/heartbeat.py`

**BUG 6: `/scans/batch` silently drops all but the last image pair**
- Edge client uploads all session batches at once (multiple raw+IR pairs per submit)
- API takes only `pair_count - 1` (the last pair), silently discards earlier pairs
- No error or warning returned to caller
- **File:** `api-server/app/routers/scans.py` lines 139–144

**BUG 7: `POST /sessions/{id}/submit` allows double-submit**
- No status check before submitting — can re-submit a session already in `graded` state
- **File:** `edge-client/src/app.py`

**BUG 8: `results.status` column is always stuck at `'pending'`**
- Migration 001 added `status TEXT NOT NULL DEFAULT 'pending'` to results table
- `scans.py` insert never sets `status`; nothing in the codebase ever updates it to `'processing'` or `'graded'`
- **File:** `api-server/app/routers/scans.py` lines 58–65; `docs-and-architecture/migrations/001_kiosk_grading_flow.sql`

---

### 🟢 Minor

**BUG 9: `contrasting_types_pct` hardcoded to `0.0`**
- Always passes this parameter — cannot fail a grade on contrasting variety types per PNS/BAFS 290:2025
- Requires rice variety metadata to compute properly
- **File:** `ai-vision-model/inference/grader.py`

**BUG 10: `edge.client.md` spec is outdated**
- Spec says `electron/` → actual code is in `electron-app/`
- Spec says `queue_manager.py` → actual file is `session_manager.py`
- Spec says `FLASK_PORT=5000` → `.env.example` uses `5055`
- **File:** `docs-and-architecture/edge-client/edge.client.md`

---

## The Critical Missing Piece: Metrics Contract

The root cause of Bugs 1–3 is the absence of a transformation layer between what the vision model produces and what the database/analytics layer expects.

**Fix requires:**
1. Run inference pipeline in `POST /scans` after image upload
2. Transform vision model output into the canonical `metrics` JSONB shape (see `api-server/metrics-contract.md`)
3. Write that `metrics` object to the result row instead of `{}`
4. Update `results.status` to `'graded'` on success or `'failed'` on error

**Grade mapping** (vision model → analytics A/B/C/D):
| Vision Model Output | Analytics Grade |
|---------------------|----------------|
| `Premium`, `Grade No. 1` | `A` |
| `Grade No. 2`, `Grade No. 3` | `B` |
| `Grade No. 4` | `C` |
| `Grade No. 5`, `Off-Grade` | `D` |

---

## Bug Fix Priority Order

1. **BUG 4** — Install `paho-mqtt` (unblocks server startup)
2. **BUG 1 + 2 + 3** — Wire inference into `POST /scans` + implement metrics contract (unblocks all analytics)
3. **BUG 8** — Update `results.status` lifecycle in scans router
4. **BUG 5** — Implement `heartbeat.py` (unblocks Pi deployment)
5. **BUG 6** — Fix batch endpoint to process all pairs, not just the last
6. **BUG 7** — Add double-submit guard in edge-client session submit
7. **BUG 9** — Implement `contrasting_types_pct` (needs variety metadata)
8. **BUG 10** — Update `edge.client.md` to match actual file structure
