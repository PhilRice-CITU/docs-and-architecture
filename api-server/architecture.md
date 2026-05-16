# api-server architecture

> Day-to-day reference for working in [/api-server](../../api-server). For the *why* behind this layout, see the design spec at [`docs/superpowers/specs/2026-05-09-api-server-architecture-design.md`](../../docs/superpowers/specs/2026-05-09-api-server-architecture-design.md).

---

## At a glance

The api-server is a FastAPI app organised in four layers. Every HTTP request flows in one direction:

```
HTTP request
     │
     ▼
routers/        — translate HTTP ↔ Python; no DB access, no business rules
     │
     ▼
services/       — business logic, orchestration, multi-step workflows
     │           ┌──── grading/  ───── YOLOv8 ONNX inference + PNS/BAFS 290:2025 grading
     │           ├──── adapters/ ───── external systems (Roboflow)
     │           │
     ▼           ▼
repositories/   — only place that touches Supabase (table + storage)
     │
     ▼
Supabase (Postgres + Storage)
```

There are two top-level router subpackages, each with its own auth model:

- `routers/edge/` — called by the Raspberry Pi edge-client. Auth: `X-Device-ID` header (or `device_id` in the body for the legacy `/scans` path).
- `routers/dashboard/` — called by the React web dashboard. Auth: Supabase JWT in `Authorization: Bearer <token>`.

These never call each other. Both consume the same `services/` and `repositories/` underneath.

---

## Directory tree

```
app/
├── main.py                          — FastAPI factory, CORS, lifespan, router mounts
├── config.py                        — pydantic-settings; all env vars
├── dependencies.py                  — get_supabase, get_current_user, JWT verification
│
├── routers/                         — HTTP layer (audience-split)
│   ├── __init__.py
│   ├── edge/                        — X-Device-ID auth
│   │   ├── __init__.py              — APIRouter aggregator (mounts /edge/v1 + legacy /scans)
│   │   ├── deps.py                  — require_device(X-Device-ID) FastAPI dep
│   │   ├── scans.py                 — POST /scans, POST /scans/batch (legacy edge upload)
│   │   ├── sessions.py              — /edge/v1/sessions/... session CRUD + submit
│   │   └── devices.py               — /edge/v1/devices/{provision,claim,upload-training,status}
│   └── dashboard/                   — Supabase JWT auth
│       ├── __init__.py              — APIRouter aggregator
│       ├── results.py               — /results/... (list, get, image variant, grain corrections)
│       ├── devices.py               — /devices/... (list, create, disconnect)
│       ├── analytics.py             — /analytics + /trends + /dashboard
│       ├── events.py                — /device-events list + create
│       ├── regions.py               — /regions list
│       └── suggestions.py           — /suggestions list + create
│
├── services/                        — business logic (no HTTP, no SQL)
│   ├── scan_service.py              — ingest_scan(): validate device, upload images, insert pending row
│   ├── grading_service.py           — grade_result() background task; render_annotated overlay
│   ├── annotation_service.py        — apply_grain_corrections, apply_grade_override + audit
│   ├── result_service.py            — list/get/patch/image-list/signed-url + visibility checks
│   ├── device_service.py            — device CRUD + status normalization + heartbeat staleness
│   ├── device_provisioning_service.py — provision/claim flow used by /edge/v1/devices
│   ├── device_event_service.py      — emit() audit-event helper (filtered by event_persistence)
│   ├── device_auth_service.py       — verify_edge_device_secret (uses utils/device_auth crypto)
│   ├── analytics_service.py         — summary, trends, dashboard aggregation
│   └── training_upload_service.py   — Roboflow upload orchestration
│
├── grading/                         — inference + grading (in-process, not an adapter)
│   ├── inference.py                 — RiceGrader class (model load, detect, merge, post-process)
│   ├── grader.py                    — grade_from_per_grain, GRADE_THRESHOLDS, PARAMETER_ORDER, CLASS_COLORS
│   ├── features.py                  — per-grain feature extraction, PX_PER_MM, MM_PER_PX
│   ├── constants.py                 — MASS_PER_MM2 calibration table
│   └── report.py                    — build_payload, build_report, save_excel
│
├── repositories/                    — only modules allowed to import supabase
│   ├── results_repo.py              — results table CRUD + lifecycle (pending/processing/graded/failed/corrected)
│   ├── result_images_repo.py        — result_images CRUD + replace_annotated
│   ├── corrections_repo.py          — result_corrections audit log
│   ├── devices_repo.py              — devices CRUD + region scoping helpers
│   ├── device_events_repo.py        — device_events insert + filtered list
│   ├── device_secrets_repo.py      — read stored device secret hashes
│   ├── edge_sessions_repo.py        — edge_sessions get/insert/update
│   ├── regions_repo.py              — regions list_all/list_minimal/get_by_code
│   ├── suggestions_repo.py          — suggestions list/insert
│   ├── analytics_repo.py            — read-only metrics queries (summary, trends, dashboard)
│   └── storage_repo.py              — Supabase Storage upload/download/signed-url
│
├── adapters/                        — external systems
│   └── roboflow.py                  — upload_image() to Roboflow dataset API
│
├── schemas/                         — Pydantic request/response models, no logic
│   ├── results.py, scans.py, corrections.py, analytics.py, devices.py,
│   ├── events.py, regions.py, suggestions.py, edge.py
│
└── utils/                           — pure helpers (no I/O)
    ├── auth_roles.py                — require_admin guard
    ├── datetime_parsing.py          — parse_iso() ISO 8601 helper
    ├── device_auth.py               — pbkdf2 hash + verify (no DB access)
    ├── event_persistence.py         — should_persist_device_event filter
    ├── metrics.py                   — build_metrics + regrade_metrics for results.metrics JSONB
    └── scoping.py                   — resolve_scoped_device_ids + resolve_visible_device

tests/
└── test_layering.py                 — static checks that pin the architecture in place
```

---

## Layering rules

```
routers/edge/      may import:  schemas/, services/, dependencies, fastapi
routers/dashboard/ may import:  schemas/, services/, dependencies, fastapi
services/          may import:  schemas/, repositories/, adapters/, utils/, other services/
repositories/      may import:  supabase + stdlib (typing only from schemas)
adapters/          may import:  the external library + stdlib
utils/             may import:  fastapi (for HTTPException), stdlib  ── never supabase
schemas/           may import:  pydantic, typing, datetime  ── never anything app-internal
```

**Hard bans:**

| Banned | Why |
|---|---|
| `services/`, `repositories/`, `adapters/` import `app.routers.*` | Business logic must not depend on the HTTP layer. |
| `routers/edge/*` import `routers/dashboard/*` (and vice versa) | The two audiences never overlap; isolate them so wrong-auth bugs are impossible. |
| `routers/*` contain the literal `supabase.table(` or `supabase.storage.` | Repositories own DB access. Routers go through services → repos. |
| `utils/*` import `supabase` | Utils are pure. If you need DB I/O it's a service or a repo. |

ruff's `TID251` enforces "no `app.routers` imports" globally; the rest are enforced by `tests/test_layering.py` (see [Enforcement](#enforcement) below).

---

## Audience split

| Subpackage | Auth | URL prefixes | Caller |
|---|---|---|---|
| `routers/edge/` | `X-Device-ID` header (or `device_id` form field for `/scans`) | `/edge/v1/sessions/...`, `/edge/v1/devices/...`, `/scans`, `/scans/batch` | edge-client (Raspberry Pi) |
| `routers/dashboard/` | Supabase JWT in `Authorization: Bearer <token>` | `/results/...`, `/devices/...`, `/analytics/...`, `/device-events`, `/live/...`, `/regions`, `/suggestions` | web-dashboard (React) |

**Why split:** the two audiences use different auth mechanisms and have zero endpoint overlap. Splitting at the directory level makes wrong-auth bugs structurally impossible (an admin endpoint can't accidentally accept `X-Device-ID`).

**Shared infrastructure:** services and repositories are *not* split — `scan_service` is called by both `routers/edge/scans.py` (legacy upload) and `routers/edge/sessions.py` (current submit flow), and a future dashboard re-ingest endpoint would call the same service. The business logic is one canonical implementation.

---

## Per-layer file map

### routers/

Thin HTTP adapters. Each handler validates the path/query/body, calls a service, and shapes the response. No `supabase.table(...)` calls.

| File | Endpoints |
|---|---|
| `routers/edge/scans.py` | `POST /scans`, `POST /scans/batch` (legacy edge upload paths kept for compat) |
| `routers/edge/sessions.py` | `POST /edge/v1/sessions`, `GET /{id}`, `PATCH /{id}`, `POST /{id}/batches`, `POST /{id}/submit` |
| `routers/edge/devices.py` | `GET /edge/v1/devices/regions`, `POST /provision`, `POST /claim`, `POST /{id}/upload-training`, `GET /{id}/status` |
| `routers/edge/deps.py` | `require_device()` FastAPI dependency for X-Device-ID auth |
| `routers/dashboard/results.py` | `GET /results`, `GET /{id}`, `GET /{id}/image`, `GET /{id}/images`, `PATCH /{id}/grains`, `POST /{id}/grade-override`, `GET /{id}/corrections`, `PATCH /{id}` |
| `routers/dashboard/devices.py` | `GET /devices`, `POST /`, `POST /{id}/disconnect` |
| `routers/dashboard/analytics.py` | `GET /analytics`, `GET /trends`, `GET /dashboard` |
| `routers/dashboard/events.py` | `GET /device-events`, `POST /device-events` |
| `routers/dashboard/regions.py` | `GET /regions` |
| `routers/dashboard/suggestions.py` | `GET /suggestions`, `POST /suggestions` |

### services/

Business logic. Orchestrates repositories + adapters; raises `HTTPException` for caller-visible errors.

| File | Public surface |
|---|---|
| `scan_service.py` | `ingest_scan(...)` → `IngestedScan` |
| `grading_service.py` | `grade_result(...)` background task; `render_annotated(...)`, `upload_annotated(...)`, `CLASS_COLORS` |
| `annotation_service.py` | `apply_grain_corrections(...)`, `apply_grade_override(...)` |
| `result_service.py` | `list_results`, `get_result`, `list_images_for_result`, `list_images_across_results`, `get_signed_url_by_variant`, `get_signed_url_by_image_id`, `list_corrections`, `patch_result_fields`, `ensure_visible` |
| `device_service.py` | `list_devices`, `create_device`, `disconnect_device`, `to_response` |
| `device_provisioning_service.py` | `provision(...)`, `claim(...)` |
| `device_event_service.py` | `emit(...)` (filtered by `should_persist_device_event`) |
| `device_auth_service.py` | `verify_edge_device_secret(...)` |
| `analytics_service.py` | `get_summary`, `get_trends`, `get_dashboard` |
| `training_upload_service.py` | `upload_pair(...)` (Roboflow IR + raw) |

### repositories/

Single allowed entry point to Supabase. Functions return raw dicts; services map to schemas. No `HTTPException` raises here — `None` and exceptions only.

| File | Public surface |
|---|---|
| `results_repo.py` | `get_by_id`, `get_id_device_created`, `insert_pending`, `list_for_devices`, `update_status`, `mark_failed`, `mark_graded`, `mark_corrected`, `patch_fields` |
| `result_images_repo.py` | `insert_pair`, `replace_annotated`, `list_for_result`, `latest_for_variant`, `get_by_id` |
| `corrections_repo.py` | `insert`, `list_for_result` |
| `devices_repo.py` | `get_status`, `get_by_id`, `list_ids_for_region`, `list_display_names`, `get_display_name`, `update`, `list_all_for_user`, `insert`, `get_first_region_id` |
| `device_events_repo.py` | `insert`, `list_filtered` |
| `device_secrets_repo.py` | `get_secret_hash` |
| `edge_sessions_repo.py` | `get`, `insert`, `update` |
| `regions_repo.py` | `list_all`, `list_minimal`, `get_by_code` |
| `suggestions_repo.py` | `list_newest`, `insert` |
| `analytics_repo.py` | `list_metrics`, `list_results_with_meta`, `list_devices_for_dashboard`, `list_results_in_window` |
| `storage_repo.py` | `upload_jpeg`, `download`, `signed_url` |

### grading/

In-process inference + grading. Not an adapter — this is a first-party package inside the app. Services import directly.

| File | Public surface |
|---|---|
| `inference.py` | `RiceGrader` (load + invoke ONNX models), `create_default_grader()` |
| `grader.py` | `grade_from_per_grain`, `grade_supported_factors`, `GRADE_THRESHOLDS`, `PARAMETER_ORDER`, `CLASS_COLORS`, `build_report_grader_result` |
| `features.py` | `PX_PER_MM`, `MM_PER_PX`, per-grain dimensional + IR feature extraction |
| `constants.py` | `MASS_PER_MM2` per-class calibration table |
| `report.py` | `build_payload`, `build_report`, `save_excel` |

### adapters/

External-system wrappers. Each module owns one external dependency.

| File | What it wraps |
|---|---|
| `roboflow.py` | `upload_image(...)` → Roboflow dataset upload API; tries 3 endpoint shapes for resilience. |

### utils/

Pure functions. Safe to import from anywhere.

| File | Public surface |
|---|---|
| `auth_roles.py` | `require_admin(current_user)`, `ADMIN_ROLES` constant |
| `datetime_parsing.py` | `parse_iso(value)` — single ISO 8601 parser used everywhere |
| `device_auth.py` | `hash_device_secret`, `verify_device_secret_hash` (pbkdf2; no I/O) |
| `event_persistence.py` | `should_persist_device_event(level, message, meta)` filter |
| `metrics.py` | `build_metrics(report)`, `regrade_metrics(metrics, grade_result)`, `GRADE_TO_LETTER` mapping |
| `scoping.py` | `resolve_scoped_device_ids`, `resolve_visible_device` (uses `devices_repo` for I/O; supabase typed as `Any` to keep the file pure) |

---

## Cross-cutting flows

### 1. Scan ingest + async grading

The hot path the kiosk uses every capture.

```
edge-client
   │  POST /edge/v1/sessions/{id}/submit (multipart raw + ir images)
   ▼
routers/edge/sessions.py::submit_session
   │
   ├─► services/scan_service.py::ingest_scan
   │       │
   │       ├─► repositories/devices_repo.py::get_status        (verify device exists & online)
   │       ├─► repositories/storage_repo.py::upload_jpeg × 2   (raw.jpg + ir.jpg)
   │       ├─► repositories/results_repo.py::insert_pending    (status='pending')
   │       └─► repositories/result_images_repo.py::insert_pair (led + noir rows)
   │
   ├─► (immediate 202 response with result_ids)
   │
   └─► BackgroundTasks.add_task(grading_service.grade_result, ...)
           │
           ▼  (runs after response is sent)
       services/grading_service.py::grade_result
           │
           ├─► repositories/results_repo.py::update_status('processing')
           ├─► repositories/storage_repo.py::download × 2
           ├─► grading/inference.py::RiceGrader.grade  (YOLOv8 ONNX + post-process per-grain)
           ├─► grading/grader.py::grade_from_per_grain (aggregate PNS/BAFS 290:2025 grade)
           ├─► grading/report.py::build_payload        (canonical report dict)
           ├─► utils/metrics.py::build_metrics
           ├─► render_annotated(...)
           ├─► repositories/storage_repo.py::upload_jpeg (annotated.jpg)
           ├─► repositories/result_images_repo.py::replace_annotated
           └─► repositories/results_repo.py::mark_graded   (status='graded', metrics=..., stub_mode=...)
```

If anything throws inside `grade_result`, the outer `except` calls `results_repo.mark_failed(result_id, error)` so the dashboard can show the failure with the error message.

### 2. Dashboard scan detail

What loads when the user opens a scan in the dashboard.

```
dashboard
   │  GET /results/{id}   Authorization: Bearer <jwt>
   ▼
routers/dashboard/results.py::get_result
   │
   └─► services/result_service.py::get_result
           │
           ├─► result_service.ensure_visible
           │       │
           │       ├─► utils/scoping.py::resolve_scoped_device_ids
           │       │       └─► repositories/devices_repo.py::list_ids_for_region (admins only)
           │       └─► repositories/results_repo.py::get_id_device_created (404 if outside scope)
           │
           └─► repositories/results_repo.py::get_by_id  → ResultResponse(**row)
```

The same `ensure_visible` is reused by every result-id-scoped endpoint (image variant, grain corrections, grade override, corrections list).

### 3. Grain correction

Admin reclassifies a grain in the dashboard.

```
dashboard
   │  PATCH /results/{id}/grains  body: {edits: [{grain_id, to_class}, ...]}
   ▼
routers/dashboard/results.py::correct_grain_classes
   │
   ├─► utils/auth_roles.py::require_admin(current_user)
   ├─► services/result_service.py::ensure_visible(...)
   └─► services/annotation_service.py::apply_grain_corrections
           │
           ├─► repositories/results_repo.py::get_by_id   (snapshot metrics_before)
           ├─► (mutate per-grain class_label in memory)
           ├─► grading/grader.py::grade_from_per_grain   (recompute aggregate grade — NO inference re-run)
           ├─► utils/metrics.py::regrade_metrics         (build metrics_after)
           ├─► repositories/results_repo.py::mark_corrected(metrics_after)
           ├─► repositories/corrections_repo.py::insert  (audit row with before+after)
           └─► re-render annotated overlay:
                  storage_repo.download(raw.jpg) → render_annotated → storage_repo.upload_jpeg
                  → result_images_repo.replace_annotated
```

`apply_grade_override` follows the same shape but skips the `grade_from_per_grain` re-run — it just edits `metrics["rawGrade"]` and sets `metrics["gradeOverridden"] = True`.

---

## Enforcement

### ruff (`pyproject.toml` `[tool.ruff.lint]`)

**Rule set**: `E` (pycodestyle), `F` (pyflakes), `I` (isort), `B` (bugbear), `UP` (pyupgrade), `SIM` (simplify), `RUF` (ruff-specific), `TID` (tidy-imports), `N` (pep8-naming).

**Ignores**:
- `B008` — FastAPI uses `Depends()` in defaults (framework idiom).
- `RUF012` — pydantic-settings allows mutable class attrs.
- `TID252` — relative imports (`from ..config import …`) are the codebase convention.
- `E501` — long lines tolerated in legacy files; new files should stay under 100.

**Banned import**:
```toml
[tool.ruff.lint.flake8-tidy-imports.banned-api]
"app.routers".msg = "services, repositories, and adapters must not import routers"
```

**Per-file ignores**:
- `app/main.py` — exempt from `TID251` because the FastAPI factory's whole job is wiring routers.
- `app/routers/**/*.py` — exempt from `TID251` because routers may import sibling routers (e.g. `from .deps import require_device`).

### `tests/test_layering.py`

Seven static checks that ruff can't express. Run with `pytest tests/test_layering.py`.

| Test | Catches |
|---|---|
| `test_layer_does_not_import_routers[services]` | a service importing `app.routers.*` |
| `test_layer_does_not_import_routers[repositories]` | a repo importing `app.routers.*` |
| `test_layer_does_not_import_routers[adapters]` | an adapter importing `app.routers.*` |
| `test_utils_do_not_touch_supabase` | a util importing `supabase` (HTTPException is fine) |
| `test_dashboard_routers_do_not_import_edge_routers` | cross-audience leakage in the dashboard direction |
| `test_edge_routers_do_not_import_dashboard_routers` | cross-audience leakage in the edge direction |
| `test_routers_do_not_call_supabase_directly` | the literal strings `supabase.table(` or `supabase.storage.` in any router file |

A regression in any of these fails CI.

---

## How to add a new endpoint

### Recipe A: a new dashboard read endpoint

Example: `GET /results/{id}/foo`.

1. **Schema** — add a Pydantic response model in [`app/schemas/results.py`](../../api-server/app/schemas/results.py) (or a new `app/schemas/foo.py` if it's a new domain).
2. **Repo** — if a new query is needed, add a function to the relevant repo (e.g. `results_repo.get_foo(supabase, result_id)`). Repos return raw dicts or `None`.
3. **Service** — add a function in the relevant service that does scoping + business logic. For result-scoped endpoints, call `result_service.ensure_visible(...)` first.
4. **Router** — add the handler in `app/routers/dashboard/results.py`. It should be ~5 lines: parse args, call the service, return the response.

### Recipe B: a new edge-protocol endpoint

Example: `POST /edge/v1/sessions/{id}/foo`.

1. **Schema** — add the request/response models in `app/schemas/edge.py`.
2. **Repo** — extend the relevant repo (most edge endpoints touch `edge_sessions_repo` or `devices_repo`).
3. **Service** — add to the matching `*_service.py` (or create `edge_session_service.py` if you're growing the surface area).
4. **Router** — add the handler in `app/routers/edge/sessions.py` (or `devices.py`). Use `Depends(require_device)` from `routers/edge/deps.py` for X-Device-ID auth.

### Recipe C: a new external-system integration

Example: integrating with an SMS provider for alerts.

1. **Adapter** — create `app/adapters/sms.py`. Wrap the provider's SDK or HTTP API behind a small Python interface. The adapter knows nothing about the database.
2. **Service** — create `app/services/alerting_service.py` that consumes the adapter and any repos it needs.
3. **Router** — add a router endpoint *only if* the alert is triggered by an HTTP call. If it's triggered by a scheduled or background job, wire it directly wherever the event fires.
4. **Config** — add new env vars to `app/config.py` (e.g. `sms_api_key`).

---

## Where things live

Quick lookup. "I want to change X → edit Y."

| Topic | File(s) |
|---|---|
| Add an env var | `app/config.py` |
| Dashboard auth (verify JWT) | `app/dependencies.py::get_current_user` |
| Edge auth (X-Device-ID) | `app/routers/edge/deps.py::require_device` |
| Edge device secret crypto | `app/utils/device_auth.py` (pure) + `app/services/device_auth_service.py` (verify) |
| Region scoping (admin → region) | `app/utils/scoping.py` |
| Admin/superadmin role guard | `app/utils/auth_roles.py::require_admin` |
| Supabase Storage uploads + signed URLs | `app/repositories/storage_repo.py` |
| YOLOv8 ONNX inference | `app/grading/inference.py::RiceGrader` |
| PNS/BAFS 290:2025 grade thresholds | `app/grading/grader.py::GRADE_THRESHOLDS` |
| Aggregate grade from per-grain | `app/grading/grader.py::grade_from_per_grain` |
| Per-grain feature extraction + PX_PER_MM | `app/grading/features.py` |
| Render annotated bbox overlay | `app/services/grading_service.py::render_annotated` + `CLASS_COLORS` |
| `results.metrics` JSONB shape | `app/utils/metrics.py` (also see [`metrics-contract.md`](metrics-contract.md)) |
| Roboflow upload | `app/adapters/roboflow.py` + `app/services/training_upload_service.py` |
| Device event audit emission | `app/services/device_event_service.py::emit` |
| ISO 8601 datetime parsing | `app/utils/datetime_parsing.py::parse_iso` |
| FastAPI app factory (mount routers, lifespan) | `app/main.py` |

---

## Known carry-overs

Things that are intentionally not refactored further, with the reason:

- **`routers/edge/sessions.py` is 241 lines.** Just under the 250 target. The `submit_session` handler does a lot because the endpoint *is* the multi-image batch contract. Splitting it further would obscure the flow.
- **`utils/scoping.py` types `Client` as `Any`.** The supabase client only passes through to `devices_repo`; importing the real type would re-introduce the layering violation. The `Any` alias is a deliberate seam.
- **`grading/` is inside `app/`, not a sibling package.** Earlier the inference pipeline lived in a separate `ai-vision-model` repo and was imported via a `sys.path` shim. That repo and shim were removed; the grading code is now a first-party in-process package. Services import directly from `app.grading`.
- **`regions.py` and `suggestions.py` aren't deeply abstracted.** They each do one thing (region list, suggestion list/insert). Adding a service layer for endpoints with no business logic is overhead.
