# Rice Vision — Claude Project Instructions

Paste the content of this file into the "Instructions" field of your Claude.ai project. It gives Claude full context about the system so every chat session starts with a complete picture.

---

## What This Project Is

**Rice Vision** is an automated rice quality grading system for a thesis project, compliant with **PNS/BAFS 290:2025** (Philippine National Standard for Milled Rice — Grading and Classification). It uses computer vision on a Raspberry Pi rig to photograph and grade rice samples using a dual-camera setup (white LED + infrared).

The system has 4 active codebases and 1 documentation repo:

| Repo | Stack | Port | Status |
|------|-------|------|--------|
| `ai-vision-model` | Python, OpenCV, ONNX | — | ✅ Complete |
| `api-server` | FastAPI, Supabase, Python 3.11+ | 3001 | ⚠️ Inference not wired |
| `edge-client` | Flask, Electron, React 19 | Flask:5055 | ⚠️ Partial mock data |
| `web-dashboard` | React 19, Vite, TanStack | 3000 | ⚠️ Partial mock data |
| `docs-and-architecture` | Markdown, SQL | — | Reference only |

---

## System Architecture

```
Raspberry Pi (edge-client)
  ├── Electron kiosk UI (React 19 + TanStack Router)
  │     └── HTTP polls Flask on localhost:5055
  ├── Flask API (src/app.py) — session CRUD, capture trigger, webhook receiver
  └── uploader.py — polls upload_queue.json → POST /scans/batch to cloud API

           │ POST /scans/batch (multipart: raw + ir images)
           ▼

Rice Vision API (api-server, FastAPI on port 3001)
  ├── POST /scans → upload images to Supabase Storage → run inference → store metrics
  ├── GET /results, PATCH /results/{id}
  ├── GET /analytics, GET /analytics/trends, GET /analytics/dashboard
  ├── GET /devices, GET /regions
  └── MQTT bridge (paho-mqtt) for real-time device commands

           │ Supabase JWT (Bearer token)
           ▼

React Web Dashboard (web-dashboard, Vite on port 3000)
  └── Analytics, device management, scan results, role-based access

           │ Both API server and dashboard connect to:
           ▼

Supabase (PostgreSQL + Storage)
  ├── Tables: regions, users, devices, results, result_images, suggestions
  └── Storage bucket: result-images (private)
         ├── results/{result_id}/raw.jpg   (white LED image)
         └── results/{result_id}/ir.jpg    (infrared image)
```

---

## Data Flow (End to End)

1. Operator taps "Grade Rice" on Pi touchscreen → Electron calls `POST /sessions` on Flask
2. Operator presses physical button → `capture.sh` triggers dual-camera shot (IR + white LED)
3. `uploader.py` picks up `upload_queue.json` entry → POSTs to `api-server POST /scans/batch`
4. API uploads images to Supabase Storage, runs `ai-vision-model` inference pipeline, stores graded `metrics` JSON in `results` table
5. React web dashboard fetches `GET /results` and `GET /analytics` with Supabase JWT
6. Admin can update `rice_variety` and `operator_name` via `PATCH /results/{id}`

**Step 4 is currently not implemented** — see Bug 1 below.

---

## Auth Model

**Dashboard users** — Supabase JWT in `Authorization: Bearer <token>` header
- `admin` role: scoped to their `region_id` only
- `superadmin` role: all regions

**Edge devices** — No JWT. Identified by `device_id` UUID in multipart form body. `device_id` must exist in the `devices` table.

`SUPABASE_SERVICE_ROLE_KEY` bypasses RLS — it is only used in the FastAPI backend, never exposed to the frontend.

---

## Database Schema (Key Tables)

```
regions (id, name, code)
users (id → auth.users, first_name, last_name, role, region_id)
devices (id, display_name, status, region_id)
results (id, device_id, operator_name, rice_variety, metrics JSONB, status, batch_name, callback_url)
result_images (id, result_id, camera_type: 'led'|'noir', storage_url, batch_number)
suggestions (id, title, body, user_id)
```

Source of truth: `docs-and-architecture/api-server/database-schema.md`
Migration 001 (applied): adds `status`, `batch_name`, `callback_url` to results; adds `batch_number` to result_images.

---

## The Critical Missing Piece: Metrics Contract

The `results.metrics` JSONB field must bridge the vision model output to the analytics layer. **This is the most important unimplemented feature.**

### Vision model output (what `ai-vision-model/inference/report.py` produces):
```json
{
  "grade": "Grade No. 2",
  "limiting_factor": "chalky_kernels_pct",
  "grain_size_class": "long",
  "total_grains_detected": 112,
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

### What must be stored in `results.metrics` (what analytics reads):
```json
{
  "qualityGrade": "B",
  "rawGrade": "Grade No. 2",
  "qualityScore": null,
  "totalGrains": 112,
  "grainSizeClass": "long",
  "limitingFactor": "chalky_kernels_pct",
  "brokenGrains": 8.93,
  "chalkinessPercentage": 6.25,
  "discolorationPercentage": 0.71,
  "foreignMatter": 0.0,
  "moistureContent": null,
  "grainLengthMm": 6.8,
  "parameters": { ... }
}
```

### Grade mapping (vision model → analytics A/B/C/D):
| Vision Model | Analytics |
|-------------|-----------|
| `Premium`, `Grade No. 1` | `"A"` |
| `Grade No. 2`, `Grade No. 3` | `"B"` |
| `Grade No. 4` | `"C"` |
| `Grade No. 5`, `Off-Grade` | `"D"` |

Full spec and transformation code: `docs-and-architecture/api-server/metrics-contract.md`

---

## Known Bugs (Current as of 2026-04-22)

### 🔴 Critical

**BUG 1: Inference never runs on scan ingest**
- `POST /scans` uploads images and inserts `metrics: {}` — `ai-vision-model` is never called
- Every result has empty metrics → all analytics return zeros
- Fix: call inference pipeline in `api-server/app/routers/scans.py` after image upload, then call `build_metrics()` from `app/utils/metrics.py`

**BUG 2: Grade format mismatch**
- Vision model → `"Premium"`, `"Grade No. 1"` etc.
- Analytics expects → `"A"`, `"B"`, `"C"`, `"D"` in `metrics.qualityGrade`
- Fix: use `GRADE_TO_LETTER` mapping in `build_metrics()` (see metrics-contract.md)
- Files: `api-server/app/routers/analytics.py` lines 33, 156–163, 369

**BUG 3: Analytics metrics field names don't match vision model**
- Analytics reads `chalkinessPercentage`, `brokenGrains`, `totalGrains` etc.
- Vision model outputs `chalky_kernels_pct`, `broken_kernels_pct`, `total_grains_detected` etc.
- Fix: the `build_metrics()` transformation function performs this rename
- Files: `api-server/app/routers/analytics.py` lines 166–182

**BUG 4: `paho-mqtt` missing → server won't start**
- `ModuleNotFoundError: No module named 'paho'` on startup
- Fix: `pip install -e ".[dev]"` in the `api-server` directory

### 🟡 Medium

**BUG 5: `/scans/batch` silently drops all but the last image pair**
- Edge client sends all session batches; API only processes `pair_count - 1` (the last)
- Fix: iterate all pairs in `api-server/app/routers/scans.py` lines 139–144

**BUG 6: Double-submit possible on edge-client sessions**
- `POST /sessions/{id}/submit` has no guard against already-graded sessions
- Fix: check `session.status != 'graded'` before submitting in `edge-client/src/app.py`

**BUG 7: `results.status` always stuck at `'pending'`**
- Migration 001 added the `status` column, but scans router never sets it to `'graded'`
- Fix: update status in scans router after successful inference

### 🟢 Minor

**BUG 8: `contrasting_types_pct` hardcoded to `0.0`** in `ai-vision-model/inference/grader.py`

**BUG 9: `edge.client.md` spec is outdated** — references old file names (`electron/` not `electron-app/`, `queue_manager.py` not `session_manager.py`, port 5000 not 5055)

---

## ai-vision-model — Key Facts

- `python main.py --stub` works with no model file (stub mode generates synthetic grains)
- `python main.py --stub --runs 10` shows grade distribution across 10 runs
- Real model: drop `models/rice_grading.onnx`, run with `--ir` and `--normal` image paths
- `PX_PER_MM = 54.6539` in `config.py` — calibrated from a 23mm Philippine peso coin, must be recalibrated per physical rig
- IR chalky confirmation: if `ir_mean_intensity < 80` and class is `whole_clear` → override to `chalky`
- Brewer exception (PNS/BAFS 290:2025 §4.2.3.3): broken grains don't fail the grade if brewer % is within threshold

## api-server — Key Facts

- Dev server: `uvicorn app.main:app --reload --host 0.0.0.0 --port 3001`
- Install: `pip install -e ".[dev]"` (includes paho-mqtt)
- Lint: `ruff check app/` and `ruff format app/`
- Tests: `pytest`
- Interactive docs: http://localhost:3001/docs
- All settings via pydantic-settings in `app/config.py`; see `.env.example`

## edge-client — Key Facts

- Flask dev: `source .venv/bin/activate && python3 src/app.py` (port 5055)
- Electron dev: `cd electron-app && npm run dev`
- Python tests: `pytest tests/ -v` (19 tests)
- Electron tests: `cd electron-app && npm test` (39 tests)
- Camera capture only works on Pi hardware — expected failure on macOS
- Session state: JSON files in `data/sessions/` — `session_manager.py` is the single owner

## web-dashboard — Key Facts

- Dev: `npm run dev` (port 3000)
- Lint+format: `npm run check`
- Tests: `npm run test` (Vitest unit) and `npm run test:e2e` (Playwright)
- Auth token in localStorage key `authToken`; `src/api/client.ts` injects it as Bearer
- Regenerate API types: `npx openapi-typescript http://localhost:3001/openapi.json -o src/api/types/openapi.ts`
- 6 themes in `src/lib/themes.ts` — ThemeProvider injects CSS variables on `<html>`
- `src/lib/mockData.ts` — mock data that may still drive some pages; replace with real API hooks

---

## Cross-Repo Conventions

- Image storage: `result-images` Supabase bucket, paths `results/{result_id}/raw.jpg` and `results/{result_id}/ir.jpg`
- TypeScript types for dashboard come from the live API schema — regenerate with openapi-typescript after API changes
- Database schema source of truth: `docs-and-architecture/api-server/database-schema.md`
- Metrics contract: `docs-and-architecture/api-server/metrics-contract.md`
- System status & bug tracker: `docs-and-architecture/SYSTEM_STATUS.md`
