# PNS Grading Alignment — Class Rename, Dimensional Broken/Brewers, Weight Estimation, Dynamic Contracts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the api-server grading pipeline into alignment with PNS/BAFS 290:2025. Rename the `whole` class to `clear` end-to-end (matches YOLO training labels). Implement PNS-defined `broken` (length-ratio) and `brewers` (min-axis) post-processing on top of YOLO output. Replace pixel-area-% with calibrated weight-% for rice classes. Drop `foreign` and `paddy` from grading thresholds (their thresholds are by-weight or count-per-mass and can't be approximated visually) and surface them as count-only informational fields. Sync analytics + frontend contracts to the new dynamic factor set.

**Architecture:** Three layers change. (1) Inference adapter renames `whole→clear`. (2) Grading layer post-processes per-grain detections to enforce PNS broken/brewers definitions, then converts pixel area to grams via per-class mass-per-mm² constants, then grades using weight-%. (3) Schemas/contracts go from fixed `quality_a/b/c/d + avg_*` shape to dynamic dicts (`grade_counts`, `factor_averages`) that propagate any factor the grader emits — including the new `brewers` and the absence of `foreign/paddy/moisture/qualityScore`.

**Tech Stack:** Python (FastAPI, NumPy, OpenCV, Ultralytics YOLO), TypeScript (React 19, TanStack Query).

---

## Context

### Why this change

A code audit revealed five misalignments between the current grader and PNS/BAFS 290:2025:

1. **Class naming drift** — YOLO training labels use `clear` for no-defect grains; inference adapter ([api-server/app/grading/inference.py](api-server/app/grading/inference.py)) uses `whole` everywhere. Cosmetic but confusing; rename to match training reality.

2. **Broken kernel definition wrong** — PNS §3.2 defines broken as `length < 75% of avg whole-grain length`. Code lets YOLO label decide ([grader.py:67-68](api-server/app/grading/grader.py#L67)), no length check. YOLO is fragile here; small visual fragments get labeled broken regardless of length.

3. **Brewers not implemented** — explicitly in `UNSUPPORTED_GRADE_FACTORS`. PNS §3.1 defines brewers as passing through 1.4mm round perforation. Implementable as `min(length_mm, width_mm) < 1.4` post-processing.

4. **Wrong unit for grading** — code grades on pixel-area-% ([grader.py:86-98](api-server/app/grading/grader.py#L86)); PNS thresholds are weight-%. Within rice classes (similar density ~1.45 g/cm³, similar thickness ~1.7-2.0mm) area-% ≈ weight-% within ~10% error. For `foreign` (sand 2.6 g/cm³, husk 0.3 g/cm³) and `paddy` (with hull, 0.6 g/cm³) area-% is meaningless as weight proxy. **Decision (user)**: hybrid — calibrated weight-% for rice classes, drop foreign/paddy from grading, keep them as count-only.

5. **Dead fields persisted in metrics** — `qualityScore`, `moistureContent`, `ir_mean_intensity` are always null/zero ([metrics.py:43,51](api-server/app/utils/metrics.py#L43), [features.py:177](api-server/app/grading/features.py#L177)). Vision system has no moisture sensor; quality score never computed. Drop them.

6. **Hardcoded analytics shape** — `quality_a/b/c/d` and named `avg_*` fields in `AnalyticsSummary` make adding a factor (like `brewers`) require a schema migration. Replace with dict shapes (`grade_counts`, `factor_averages`) so any factor added downstream propagates automatically.

### Decisions (from conversation)

- **Class rename**: `whole → clear` end-to-end.
- **Broken**: length-ratio rule (`length_mm < 0.75 × mean(clear_length_mm)`), with fallback to variety-mean if no clear grains in scan.
- **Brewers**: `length_mm < 1.4 AND width_mm < 1.4`. Conservative — both axes must be small (sieve geometry).
- **Units**: hybrid. Real weight-% via per-class `mass_per_mm²` constants for rice classes (`clear`, `broken`, `brewers`, `chalky`, `discolored`, `damaged`, `red`). Drop `foreign` and `paddy` from grading; surface as count-only info on the result.
- **Scope**: full PNS alignment. Multi-week.

### Decisions deferred

- **Immature kernels**: PNS factor; no model class. Out of scope.
- **Contrasting types**: variety detection. Out of scope.
- **Degree of milling** (UMR/RMR/WMR/OMR): alcohol-alkali stain, not vision. Out of scope.
- **Calibration constants**: this plan installs sensible literature-derived defaults (long-grain indica ~21mg per grain, density ~1.45 g/cm³). Real empirical calibration is a separate one-time procedure documented in Task 4.

---

## File Structure

| Path | Change |
|---|---|
| `api-server/app/grading/inference.py` | Rename `whole→clear` in `OVERRIDABLE_NORMAL_LABELS` and any literal references |
| `api-server/app/grading/features.py` | Rename `PNS_SIZE_REFERENCE_LABELS = {"clear"}`. Add `apply_dimensional_post_processing()` that reclassifies grains as `broken`/`brewers` based on length/width. Add `area_px_to_grams()` helper |
| `api-server/app/grading/grader.py` | Add `brewers` row to `GRADE_THRESHOLDS` (Table 2 PNS values). Drop `foreign` from `PARAMETER_ORDER`. Add new aggregator `summarize_weight_percentages()` that uses `area_px_to_grams`. Keep `summarize_area_percentages` for diagnostics. Drop `paddy` from grading-relevant set; expose `paddy_count` and `foreign_count` |
| `api-server/app/grading/report.py` | Pipe new fields through. Drop `ir_mean_intensity`. Surface `foreign_count`, `paddy_count` |
| `api-server/app/grading/constants.py` (NEW) | `MASS_PER_MM2` dict per rice class. Single source of truth for calibration constants |
| `api-server/app/utils/metrics.py` | Drop `qualityScore` and `moistureContent`. Add `brewers`, `foreignCount`, `paddyCount`. `parameters` dict now keyed by the 6 PNS factors (broken/brewers/damaged/discolored/chalky/red) |
| `api-server/app/schemas/analytics.py` | Replace fixed `quality_a/b/c/d` + `avg_*` with `grade_counts: dict[str, int]` and `factor_averages: dict[str, float \| None]`. Drop `MoistureWatchEntry` and `moisture_watch`. Drop `avg_quality_score`, `avg_moisture` from trends |
| `api-server/app/services/analytics_service.py` | Aggregate every key in `metrics.parameters` dynamically. Drop `_moisture_watch`, qualityScore aggregation |
| `api-server/scripts/calibrate_mass_per_mm2.py` (NEW) | One-shot calibration helper: takes a rig photo of a known rice mass, prints `mass_per_mm²` to paste into `constants.py` |
| `web-dashboard/src/shared/api/contracts.ts` | Drop `qualityScore`, `moistureContent`. Add `brewers`, `foreignCount`, `paddyCount` to `ApiResultMetrics`. Mirror new dynamic analytics shapes. Drop `ApiDashboardMoistureWatch` |
| `web-dashboard/src/features/dashboard/types/dashboard.types.ts` | Delete `MoistureEntry`, drop `avgMoistureContent` |
| `web-dashboard/src/features/dashboard/mappers/dashboard.mappers.ts` | Delete `buildMoistureWatchData`. `buildRiceGradesData` reads `analytics.grade_counts` |
| `web-dashboard/src/features/dashboard/hooks/useDashboardData.ts` | Drop `moistureWatchData`, `avgMoistureContent` |
| `web-dashboard/src/features/dashboard/components/DashboardMetricsBar.tsx` | Remove avg-moisture metric card |
| `web-dashboard/src/features/dashboard/components/MoistureRiskPanel.tsx` | **DELETE** |
| `web-dashboard/src/pages/DashboardPage.tsx` | Drop `<MoistureRiskPanel>` |
| `web-dashboard/src/features/analytics/types/analytics.types.ts` | Drop `avgMoisture`, `avgQualityScore`. Add `avgBrokenGrains` (already), `avgBrewers`, `avgDamaged`, `avgRed` |
| `web-dashboard/src/features/analytics/utils/analytics.utils.tsx` | Adapt mapper to dict shape. `DEFAULT_METRIC = 'avgBrokenGrains'`, `secondaryMetric = 'avgChalkiness'` |
| `web-dashboard/src/features/analytics/constants/analyticsCatalog.ts` | Drop `avgMoisture`, `avgQualityScore`. Add `avgBrewers`, `avgDamaged`, `avgRed` |
| `web-dashboard/src/features/analytics/components/AnalyticsMetricsBar.tsx` | Replace moisture/score cards with broken-% + Grade-A share |
| `web-dashboard/src/features/analytics/hooks/useAnalyticsData.ts` | Replace `avgMoisture`/`avgScore` with `avgBrokenGrains`/`gradeAShare` |
| `web-dashboard/src/pages/AnalyticsPage.tsx` | Update props to AnalyticsMetricsBar |
| `web-dashboard/src/features/devices/components/DeviceStatsRow.tsx` | Iterate `data.grade_counts` |
| `web-dashboard/src/features/scans/components/GradingBreakdown.tsx` | Already iterates `parameters` dynamically; verify it renders new factors. Drop any `qualityScore` reference |
| `docs-and-architecture/api-server/grading-pipeline.md` (UPDATE or NEW) | Document fusion override, dimensional post-processing, calibration provenance, drop-list (foreign/paddy/immature/contrasting) |

---

## Task 1: Class rename `whole → clear` end-to-end (api-server)

**Files:**
- `api-server/app/grading/inference.py`
- `api-server/app/grading/features.py`
- `api-server/app/grading/grader.py`
- `api-server/app/grading/report.py`
- Any tests under `api-server/tests/`

- [ ] **Step 1:** Find every literal `"whole"` in `app/grading/`:

```bash
cd api-server && grep -rn '"whole"' app/grading/
```

- [ ] **Step 2:** In `inference.py`, change `OVERRIDABLE_NORMAL_LABELS` (line 28):

```python
OVERRIDABLE_NORMAL_LABELS = {"clear", "broken", "damaged", "discolored", "red", "paddy"}
```

- [ ] **Step 3:** In `features.py`, change `PNS_SIZE_REFERENCE_LABELS` to `{"clear"}` and `PHYSICAL_FEATURE_EXCLUDED_LABELS` if it currently includes `"whole"` for any reason.

- [ ] **Step 4:** In `grader.py`, update `CLASS_COLORS` dict — replace key `"whole"` with `"clear"`.

- [ ] **Step 5:** Run tests + lint:

```bash
cd api-server && pytest && ruff check app/
```

If tests assert on `"whole"` literally, update them to `"clear"`.

- [ ] **Step 6:** Commit: `refactor(grading): rename whole→clear to match YOLO training labels`

---

## Task 2: Add dimensional post-processing (broken via length, brewers via min-axis)

**Files:**
- `api-server/app/grading/features.py` (add `apply_dimensional_post_processing`)
- `api-server/app/grading/grader.py` (call it before threshold grading)

- [ ] **Step 1:** Add to `features.py`:

```python
RICE_CLASSES = {"clear", "broken", "brewers", "chalky", "discolored", "damaged", "red"}
BROKEN_LENGTH_RATIO = 0.75
BREWERS_MAX_AXIS_MM = 1.4

# Variety-mean fallback when no clear grains in scan (Annex C indica long-grain mean)
FALLBACK_CLEAR_LENGTH_MM = 6.8


def _scan_clear_reference_length(detections: list[dict]) -> float:
    clear_lengths = [
        d["length_mm"] for d in detections
        if d.get("class_label") == "clear" and d.get("length_mm") is not None
    ]
    if clear_lengths:
        return statistics.mean(clear_lengths)
    rice_lengths = [
        d["length_mm"] for d in detections
        if d.get("class_label") in RICE_CLASSES and d.get("length_mm") is not None
    ]
    if rice_lengths:
        return statistics.median(rice_lengths)
    return FALLBACK_CLEAR_LENGTH_MM


def apply_dimensional_post_processing(detections: list[dict]) -> list[dict]:
    """Reclassify grains per PNS dimensional definitions.
    
    Order matters: brewers test first (most restrictive), then broken.
    A grain that's both <1.4mm minor axis AND <0.75 of clear-mean length is brewers.
    """
    reference_length = _scan_clear_reference_length(detections)
    broken_threshold_mm = BROKEN_LENGTH_RATIO * reference_length
    
    out = []
    for det in detections:
        new_det = dict(det)
        label = det.get("class_label")
        length = det.get("length_mm")
        width = det.get("width_mm")
        
        # Only rice classes get reclassified; foreign/paddy untouched
        if label not in RICE_CLASSES or length is None or width is None:
            out.append(new_det)
            continue
        
        # Brewers: both axes below 1.4mm sieve
        if length < BREWERS_MAX_AXIS_MM and width < BREWERS_MAX_AXIS_MM:
            new_det["class_label"] = "brewers"
            new_det["reclassified_from"] = label
        # Broken: length below 75% reference
        elif length < broken_threshold_mm and label != "broken":
            new_det["class_label"] = "broken"
            new_det["reclassified_from"] = label
        
        out.append(new_det)
    return out
```

- [ ] **Step 2:** In `grader.py`, call this **after** fusion and **before** area/weight aggregation. Trace where `to_enriched_grains()` output flows into `grade_from_per_grain` / aggregators and inject the post-processing step there.

- [ ] **Step 3:** Add unit tests at `api-server/tests/grading/test_dimensional_post_processing.py`:
  - All clear, all >0.75 length → no reclassification
  - One short grain → reclassified to broken
  - One tiny grain (both axes <1.4) → reclassified to brewers (not broken)
  - No clear grains in scan → uses median fallback
  - Empty scan → no error, returns []

- [ ] **Step 4:** Lint + tests:

```bash
cd api-server && pytest && ruff check app/
```

- [ ] **Step 5:** Commit: `feat(grading): post-process broken/brewers per PNS dimensional rules`

---

## Task 3: Add brewers to grading thresholds, drop foreign/paddy

**File:** `api-server/app/grading/grader.py`

- [ ] **Step 1:** Add brewers row to `GRADE_THRESHOLDS` per PNS Table 2:

```python
GRADE_THRESHOLDS = {
    "Premium":     {"broken": 5.0,  "brewers": 0.10, "damaged": 0.5, "discolored": 0.5, "chalky": 4.0,  "red": 1.0},
    "Grade no. 1": {"broken": 10.0, "brewers": 0.20, "damaged": 0.7, "discolored": 0.7, "chalky": 5.0,  "red": 2.0},
    "Grade no. 2": {"broken": 15.0, "brewers": 0.40, "damaged": 1.0, "discolored": 1.0, "chalky": 7.0,  "red": 4.0},
    "Grade no. 3": {"broken": 25.0, "brewers": 0.60, "damaged": 1.5, "discolored": 3.0, "chalky": 9.0,  "red": 5.0},
    "Grade no. 4": {"broken": 35.0, "brewers": 1.00, "damaged": 2.0, "discolored": 5.0, "chalky": 12.0, "red": 6.0},
    "Grade no. 5": {"broken": 45.0, "brewers": 2.00, "damaged": 3.0, "discolored": 8.0, "chalky": 15.0, "red": 7.0},
}
```

- [ ] **Step 2:** Update `PARAMETER_ORDER`:

```python
PARAMETER_ORDER = ("broken", "brewers", "damaged", "discolored", "chalky", "red")
```

- [ ] **Step 3:** Update `UNSUPPORTED_GRADE_FACTORS` (remove `brewers`, add nothing):

```python
UNSUPPORTED_GRADE_FACTORS = ("immature", "contrasting_types", "foreign", "paddy")
```

(`foreign` and `paddy` move here because their PNS units — % by weight and count-per-1000g respectively — can't be approximated visually. Surfaced as count-only info, not graded.)

- [ ] **Step 4:** Commit: `feat(grading): add brewers to PNS factors, drop foreign/paddy from grading`

---

## Task 4: Calibrated weight estimation for rice classes

**Files:**
- `api-server/app/grading/constants.py` (NEW)
- `api-server/app/grading/features.py` (`area_px_to_grams` helper)
- `api-server/app/grading/grader.py` (use weight-% in aggregation)
- `api-server/scripts/calibrate_mass_per_mm2.py` (NEW)

- [ ] **Step 1:** Create `api-server/app/grading/constants.py`:

```python
"""Calibration constants for converting grain area (mm²) to mass (g).

Defaults are literature-derived for Philippine indica long-grain rice
(1000-grain weight ≈ 21 g, density ≈ 1.45 g/cm³, mean grain area ≈ 9.6 mm²).
For production use, recalibrate per device using
scripts/calibrate_mass_per_mm2.py and paste results here.
"""

# grams per mm² (top-down projected area), per rice class.
# Same default for all rice classes; override per class once empirical data exists.
_DEFAULT_RICE_MASS_PER_MM2 = 0.0022  # ≈ 21mg/grain ÷ 9.6 mm²/grain

MASS_PER_MM2: dict[str, float] = {
    "clear":      _DEFAULT_RICE_MASS_PER_MM2,
    "broken":     _DEFAULT_RICE_MASS_PER_MM2,
    "brewers":    _DEFAULT_RICE_MASS_PER_MM2,
    "chalky":     _DEFAULT_RICE_MASS_PER_MM2,
    "discolored": _DEFAULT_RICE_MASS_PER_MM2,
    "damaged":    _DEFAULT_RICE_MASS_PER_MM2,
    "red":        _DEFAULT_RICE_MASS_PER_MM2,
}
```

- [ ] **Step 2:** Add to `features.py`:

```python
from .constants import MASS_PER_MM2

# Already defined: PX_PER_MM = 54.6539, MM_PER_PX = 1.0 / PX_PER_MM
MM2_PER_PX2 = MM_PER_PX * MM_PER_PX  # 0.000334...


def area_px_to_grams(area_px: float, class_label: str) -> float | None:
    coeff = MASS_PER_MM2.get(class_label)
    if coeff is None:
        return None
    area_mm2 = area_px * MM2_PER_PX2
    return area_mm2 * coeff
```

- [ ] **Step 3:** In `grader.py`, add a new aggregator alongside the existing area-% one:

```python
def summarize_weight_percentages(detections: list[dict]) -> dict[str, float]:
    """% by mass for rice classes only. Uses calibrated mass_per_mm² per class."""
    mass_by_label: dict[str, float] = {}
    total_rice_mass = 0.0
    for det in detections:
        label = det.get("class_label")
        if label not in MASS_PER_MM2:  # skip foreign, paddy
            continue
        area_px = det.get("area_px") or 0.0
        mass_g = area_px_to_grams(area_px, label)
        if mass_g is None:
            continue
        mass_by_label[label] = mass_by_label.get(label, 0.0) + mass_g
        total_rice_mass += mass_g
    if total_rice_mass <= 0:
        return {label: 0.0 for label in MASS_PER_MM2}
    return {label: (mass / total_rice_mass) * 100.0 for label, mass in mass_by_label.items()}
```

- [ ] **Step 4:** Replace the call site that fed `summarize_area_percentages` into grading with `summarize_weight_percentages`. Keep `summarize_area_percentages` as a diagnostic emitted under a separate key in the report (`area_percentages_diagnostic`), so the dashboard can still show area for QA but grading uses weight.

- [ ] **Step 5:** Add `foreign_count` and `paddy_count` aggregators:

```python
def summarize_count(detections: list[dict], label: str) -> int:
    return sum(1 for d in detections if d.get("class_label") == label)
```

Surface these in the report payload alongside `parameters`.

- [ ] **Step 6:** Create `api-server/scripts/calibrate_mass_per_mm2.py`:

```python
"""One-shot calibration helper.

Procedure:
  1. Weigh a known mass of pure clear-grade rice (e.g. 50.000 g).
  2. Place it in the rig, photograph with the white-LED camera.
  3. Run this script:  python scripts/calibrate_mass_per_mm2.py path/to/photo.jpg --grams 50.0
  4. It runs YOLO inference, sums area_px for the 'clear' class, prints
     mass_per_mm² (override-ready).
"""
import argparse, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.grading.inference import RiceGradingInference
from app.grading.features import MM2_PER_PX2

def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("image", help="Path to white-LED photo of weighed rice sample")
    p.add_argument("--grams", type=float, required=True)
    p.add_argument("--class", dest="cls", default="clear")
    args = p.parse_args()

    grader = RiceGradingInference()  # loads ONNX models
    result = grader._extract_detections(
        grader.normal_model.predict(source=args.image, verbose=False),
        source="normal",
    )
    target_dets = [d for d in result if d.label == args.cls]
    total_area_px = sum(d.area_px for d in target_dets)
    if total_area_px <= 0:
        sys.exit(f"No '{args.cls}' detections in image")
    total_area_mm2 = total_area_px * MM2_PER_PX2
    mass_per_mm2 = args.grams / total_area_mm2
    print(f"class={args.cls}  grains_detected={len(target_dets)}  total_area_mm²={total_area_mm2:.2f}")
    print(f"mass_per_mm² = {mass_per_mm2:.6f}  grams/mm²")
    print(f"\nPaste into app/grading/constants.py:")
    print(f'    "{args.cls}": {mass_per_mm2:.6f},')

if __name__ == "__main__":
    main()
```

- [ ] **Step 7:** Lint + tests:

```bash
cd api-server && pytest && ruff check app/
```

- [ ] **Step 8:** Commit: `feat(grading): calibrated weight-% via per-class mass_per_mm² constants`

---

## Task 5: Drop dead fields, add new ones in metrics builder

**File:** `api-server/app/utils/metrics.py`

- [ ] **Step 1:** In `build_metrics()`:
  - Remove `"qualityScore": None`
  - Remove `"moistureContent": None`
  - The `parameters` dict is already passed through dynamically, so `brewers` will appear automatically once the grader emits it.
  - Add `"foreignCount": report.get("foreign_count", 0)` and `"paddyCount": report.get("paddy_count", 0)`

- [ ] **Step 2:** In `regrade_metrics()`, mirror the same shape on regrade.

- [ ] **Step 3:** Drop `ir_mean_intensity` from per-grain payloads. In `app/grading/features.py` `to_enriched_grains`, remove the line that hard-codes `0.0`. In `app/grading/report.py`, remove from the per-grain output. Per-grain consumers in the frontend don't read it.

- [ ] **Step 4:** Commit: `refactor(metrics): drop dead fields, surface brewers/foreign/paddy counts`

---

## Task 6: Dynamic analytics schemas (api-server)

**File:** `api-server/app/schemas/analytics.py`

- [ ] **Step 1:** Replace file content:

```python
from pydantic import BaseModel


class AnalyticsSummary(BaseModel):
    total_samples: int
    grade_counts: dict[str, int]
    factor_averages: dict[str, float | None]


class AnalyticsTrendPoint(BaseModel):
    date: str
    total_grains: int
    total_samples: int
    grade_counts: dict[str, int]
    factor_averages: dict[str, float]
    avg_length_mm: float


class AnalyticsTrendsResponse(BaseModel):
    data: list[AnalyticsTrendPoint]


class GradeDistributionEntry(BaseModel):
    name: str
    value: int
    share: float
    status: str


class DashboardSummary(BaseModel):
    scans_processed_today: int
    online_devices: int
    total_devices: int
    factor_averages_today: dict[str, float | None]
    grade_distribution: list[GradeDistributionEntry]
```

- [ ] **Step 2:** Commit: `refactor(schemas): dynamic analytics shape via grade_counts/factor_averages`

---

## Task 7: Dynamic aggregation (analytics service)

**File:** `api-server/app/services/analytics_service.py`

- [ ] **Step 1:** Rewrite `_aggregate_summary` to walk every parameter key dynamically from `metrics.parameters`. New brewers/foreign keys propagate automatically.

```python
def _aggregate_summary(rows: list[dict]) -> AnalyticsSummary:
    grade_counts: dict[str, int] = {}
    factor_buckets: dict[str, list[float]] = {}
    for row in rows:
        m = row.get("metrics") or {}
        grade = _grade(m)
        if grade:
            grade_counts[grade] = grade_counts.get(grade, 0) + 1
        for key, value in (m.get("parameters") or {}).items():
            try:
                factor_buckets.setdefault(key, []).append(float(value))
            except (TypeError, ValueError):
                continue
    factor_averages = {key: _avg_or_none(vals) for key, vals in factor_buckets.items()}
    return AnalyticsSummary(
        total_samples=len(rows),
        grade_counts=grade_counts,
        factor_averages=factor_averages,
    )
```

- [ ] **Step 2:** Update `_empty_summary` → `grade_counts={}, factor_averages={}`.

- [ ] **Step 3:** Rewrite trends `_new_bucket` / `_accumulate_bucket` / `_bucket_to_point` to use dict-shaped grade_counts and factor_buckets. (Same pattern as summary.)

- [ ] **Step 4:** Rewrite `get_dashboard` to drop `_moisture_watch` entirely, drop moisture aggregation, emit `factor_averages_today` dynamically. Delete `_moisture_watch`, `MoistureWatchEntry` import, and `_MOISTURE_*` constants.

- [ ] **Step 5:** Update `_empty_dashboard` to match.

- [ ] **Step 6:** Run tests + lint:

```bash
cd api-server && pytest && ruff check app/
```

If snapshot tests fail, update them to expect the new dict shape.

- [ ] **Step 7:** Commit: `refactor(analytics): aggregate parameters dynamically, drop moisture surface`

---

## Task 8: Frontend — sync `contracts.ts`

**File:** `web-dashboard/src/shared/api/contracts.ts`

- [ ] **Step 1:** Replace `ApiAnalyticsSummary`:

```typescript
export interface ApiAnalyticsSummary {
  total_samples: number
  grade_counts: Record<string, number>
  factor_averages: Record<string, number | null>
}
```

- [ ] **Step 2:** Replace `ApiAnalyticsTrendPoint`:

```typescript
export interface ApiAnalyticsTrendPoint {
  date: string
  total_grains: number
  total_samples: number
  grade_counts: Record<string, number>
  factor_averages: Record<string, number>
  avg_length_mm: number
}
```

- [ ] **Step 3:** Delete `ApiDashboardMoistureWatch`. Replace `ApiDashboardSummary`:

```typescript
export interface ApiDashboardSummary {
  scans_processed_today: number
  online_devices: number
  total_devices: number
  factor_averages_today: Record<string, number | null>
  grade_distribution: ApiDashboardGradeDistribution[]
}
```

- [ ] **Step 4:** Update `ApiResultMetrics` — drop `qualityScore`, `moistureContent`; add `brewers`, `foreignCount`, `paddyCount`:

```typescript
export interface ApiResultMetrics {
  qualityGrade?: 'A' | 'B' | 'C' | 'D'
  totalGrains?: number
  grainSizeClass?: string
  limitingFactor?: string
  brokenGrains?: number
  brewers?: number
  chalkinessPercentage?: number
  discolorationPercentage?: number
  damagedPercentage?: number
  redKernelPercentage?: number
  foreignCount?: number
  paddyCount?: number
  grainLengthMm?: number | null
  rawGrade?: string
  gradeOverridden?: boolean
  perGrain?: ApiPerGrain[]
  parameters?: Record<string, number>
}
```

- [ ] **Step 5:** In `ApiPerGrain`, drop `ir_mean_intensity`.

- [ ] **Step 6:** Lint: `cd web-dashboard && npm run lint`. Expect failures in consumers — fixed in subsequent tasks.

---

## Task 9: Frontend — dashboard mapper, types, hook, components, page

**Files:**
- `web-dashboard/src/features/dashboard/types/dashboard.types.ts` — delete `MoistureEntry`, drop `avgMoistureContent`
- `web-dashboard/src/features/dashboard/mappers/dashboard.mappers.ts` — delete `buildMoistureWatchData`, rewrite `buildRiceGradesData` against `analytics.grade_counts`
- `web-dashboard/src/features/dashboard/hooks/useDashboardData.ts` — drop `moistureWatchData`, `avgMoistureContent`, adapt broken-grain fallback to `factor_averages_today.broken`
- `web-dashboard/src/features/dashboard/components/DashboardMetricsBar.tsx` — drop avg-moisture card
- `web-dashboard/src/features/dashboard/components/MoistureRiskPanel.tsx` — **DELETE**
- `web-dashboard/src/pages/DashboardPage.tsx` — drop `<MoistureRiskPanel>` import + JSX

- [ ] **Step 1:** Apply the changes above (mechanical drops + signature updates).

- [ ] **Step 2:** New `buildRiceGradesData` body:

```typescript
export function buildRiceGradesData(
  dashboardGrades:
    | Array<{ name: string; value: number; share: number; status: string }>
    | undefined,
  analytics: { total_samples: number; grade_counts: Record<string, number> } | undefined,
): RiceGrade[] {
  if (dashboardGrades && dashboardGrades.length > 0) {
    return dashboardGrades.map((grade) => ({
      name: grade.name,
      value: `${grade.value.toLocaleString()} samples`,
      share: Math.round(grade.share),
      status: grade.status === 'negative' ? ('negative' as const) : ('positive' as const),
    }))
  }
  if (analytics) {
    const total = Math.max(analytics.total_samples, 1)
    return (['A', 'B', 'C', 'D'] as const).map((letter) => {
      const count = analytics.grade_counts[letter] ?? 0
      return {
        name: `Grade ${letter}`,
        value: `${count.toLocaleString()} samples`,
        share: Math.round((count / total) * 100),
        status: letter === 'A' || letter === 'B' ? ('positive' as const) : ('negative' as const),
      }
    })
  }
  return [
    { name: 'Grade A', value: '0 samples', share: 0, status: 'positive' as const },
    { name: 'Grade B', value: '0 samples', share: 0, status: 'positive' as const },
    { name: 'Grade C', value: '0 samples', share: 0, status: 'negative' as const },
    { name: 'Grade D', value: '0 samples', share: 0, status: 'negative' as const },
  ]
}
```

- [ ] **Step 3:** Lint + build: `cd web-dashboard && npm run lint && npm run build`. Expect green.

- [ ] **Step 4:** Commit: `feat(dashboard): drop moisture surface, use grade_counts dict`

---

## Task 10: Frontend — analytics types, catalog, mapper, hook, components, page

**Files:**
- `web-dashboard/src/features/analytics/types/analytics.types.ts`
- `web-dashboard/src/features/analytics/utils/analytics.utils.tsx`
- `web-dashboard/src/features/analytics/constants/analyticsCatalog.ts`
- `web-dashboard/src/features/analytics/hooks/useAnalyticsData.ts`
- `web-dashboard/src/features/analytics/components/AnalyticsMetricsBar.tsx`
- `web-dashboard/src/pages/AnalyticsPage.tsx`

- [ ] **Step 1:** In `analytics.types.ts`:
  - Drop `avgMoisture`, `avgQualityScore` from `AnalyticsData`.
  - Drop them from the chart-metric union.
  - Add `avgBrewers`, `avgDamaged`, `avgRed` to `AnalyticsData` and the metric union (PNS factors that were dropped at the analytics layer despite being live in metrics.parameters).

- [ ] **Step 2:** In `analytics.utils.tsx` rewrite `mapTrendPointToAnalyticsData`:

```typescript
export function mapTrendPointToAnalyticsData(point: ApiAnalyticsTrendPoint): AnalyticsData {
  return {
    date: point.date,
    totalGrains: point.total_grains,
    totalSamples: point.total_samples,
    qualityA: point.grade_counts.A ?? 0,
    qualityB: point.grade_counts.B ?? 0,
    qualityC: point.grade_counts.C ?? 0,
    qualityD: point.grade_counts.D ?? 0,
    avgBrokenGrains: point.factor_averages.broken ?? 0,
    avgBrewers: point.factor_averages.brewers ?? 0,
    avgChalkiness: point.factor_averages.chalky ?? 0,
    avgDiscoloration: point.factor_averages.discolored ?? 0,
    avgDamaged: point.factor_averages.damaged ?? 0,
    avgRed: point.factor_averages.red ?? 0,
    avgLengthMm: point.avg_length_mm,
  }
}
```

  - Update empty-default block to match.
  - Change `DEFAULT_METRIC` from `'avgQualityScore'` to `'avgBrokenGrains'`.
  - Change `secondaryMetric` from `'avgMoisture'` to `'avgChalkiness'`.

- [ ] **Step 3:** In `analyticsCatalog.ts`:
  - Remove `avgMoisture` and `avgQualityScore` entries.
  - Add `avgBrewers`, `avgDamaged`, `avgRed` mirroring the structure of `avgChalkiness` (units `%`).

- [ ] **Step 4:** In `useAnalyticsData.ts` replace `headlineMetrics`:

```typescript
const avgBrokenGrains =
  filteredData.reduce((total, row) => total + row.avgBrokenGrains, 0) / Math.max(filteredData.length, 1)
const gradeACount = filteredData.reduce((total, row) => total + row.qualityA, 0)
const totalCount = filteredData.reduce((total, row) => total + row.totalSamples, 0)
const gradeAShare = totalCount > 0 ? (gradeACount / totalCount) * 100 : 0

return {
  samples: filteredData.length,
  avgBrokenGrains: Number(avgBrokenGrains.toFixed(2)),
  gradeAShare: Number(gradeAShare.toFixed(1)),
}
```

  - Empty-state branch: `{ samples: 0, avgBrokenGrains: 0, gradeAShare: 0 }`.

- [ ] **Step 5:** In `AnalyticsMetricsBar.tsx`, replace moisture/score cards with `avgBrokenGrains` (`%`) and `gradeAShare` (`%`). Update `Props`.

- [ ] **Step 6:** In `AnalyticsPage.tsx`, update props to `AnalyticsMetricsBar`.

- [ ] **Step 7:** Lint + build: `cd web-dashboard && npm run lint && npm run build`. Expect green.

- [ ] **Step 8:** Commit: `feat(analytics): expose all PNS factors (incl. brewers), drop moisture/qualityScore`

---

## Task 11: Frontend — DeviceStatsRow + GradingBreakdown spot fixes

**Files:**
- `web-dashboard/src/features/devices/components/DeviceStatsRow.tsx`
- `web-dashboard/src/features/scans/components/GradingBreakdown.tsx`

- [ ] **Step 1:** In `DeviceStatsRow.tsx`, read `data.grade_counts`:

```typescript
const counts = data?.grade_counts ?? {}
const grades = (['A', 'B', 'C', 'D'] as const).map((label) => ({
  label,
  count: counts[label] ?? 0,
}))
```

- [ ] **Step 2:** In `GradingBreakdown.tsx`, verify `parameters` table renders the new factor `brewers` (it iterates entries dynamically so should be automatic). Add a small section above or below the parameters table to surface `metrics.foreignCount` and `metrics.paddyCount` as count-only badges:

```typescript
{(metrics.foreignCount ?? 0) > 0 && (
  <Badge variant="outline">Foreign objects detected: {metrics.foreignCount}</Badge>
)}
{(metrics.paddyCount ?? 0) > 0 && (
  <Badge variant="outline">Paddy grains detected: {metrics.paddyCount}</Badge>
)}
```

- [ ] **Step 3:** Lint + build: `cd web-dashboard && npm run lint && npm run build`.

- [ ] **Step 4:** Commit: `refactor(devices,scans): surface new PNS factors, drop dead fields`

---

## Task 12: Documentation

**File:** `docs-and-architecture/api-server/grading-pipeline.md` (update or create)

- [ ] **Step 1:** Document:
  - Two-model fusion logic (white-LED authoritative for discolored/red/damaged, IR authoritative for chalky)
  - IoU 0.25 / center-distance 0.03 override thresholds
  - Class taxonomy: `clear, broken, brewers, chalky, discolored, damaged, red, foreign, paddy` (8 rice + 2 non-rice)
  - PNS dimensional rules: broken via `length < 0.75 × mean(clear length)`; brewers via `min(length, width) < 1.4mm`
  - Calibration: pixel→mm via 23mm coin (54.6539 px/mm), area_mm²→grams via per-class `MASS_PER_MM2` literature defaults; recalibration via `scripts/calibrate_mass_per_mm2.py`
  - **Excluded from grading**: `foreign` (% by weight, density unknowable from image), `paddy` (count-per-1000g, not %), `immature` (no model class), `contrasting_types` (variety detection, OOS), `degree_of_milling` (chemical staining, OOS)
  - **Always-null fields removed**: `qualityScore`, `moistureContent`, `ir_mean_intensity`

- [ ] **Step 2:** Commit: `docs(grading): document PNS alignment, fusion rules, calibration provenance`

---

## Verification

1. **Backend:** `cd api-server && pytest && ruff check app/` — all green. New tests in Task 2 pass.

2. **Frontend:** `cd web-dashboard && npm run lint && npm run build` — green.

3. **End-to-end smoke (with stub mode):**

```bash
# api-server
uvicorn app.main:app --reload --port 3001 &
# upload a test scan via POST /scans, then:
curl http://localhost:3001/results/{result_id} | jq '.metrics'
# Expect: parameters dict has broken/brewers/chalky/discolored/damaged/red, no foreignMatter, no qualityScore, no moistureContent
# Expect: foreignCount and paddyCount as separate fields
# Expect: rawGrade respects new brewers threshold

curl http://localhost:3001/analytics | jq
# Expect: { total_samples, grade_counts: {A,B,C,D}, factor_averages: {broken, brewers, chalky, ...} }

curl http://localhost:3001/analytics/dashboard | jq
# Expect: factor_averages_today, no moisture_watch, no avg_moisture
```

4. **UI smoke:**
   - `/dashboard` — no MoistureRiskPanel, no Avg Moisture card. Grade A/B/C/D table populated from `grade_counts`.
   - `/analytics` — chart-metric dropdown lists `avgBrokenGrains, avgBrewers, avgChalkiness, avgDiscoloration, avgDamaged, avgRed, avgLengthMm`. No avgMoisture, no avgQualityScore. Headline cards: broken-grain % and Grade-A share.
   - `/devices/:id` — grade row shows A/B/C/D counts.
   - `/scans/:id` — parameters table shows `brewers` row. Foreign/paddy badges appear when nonzero.

5. **Class rename verification:**

```bash
grep -rn '"whole"' api-server/app/grading/ web-dashboard/src/
```

Expect zero hits in production code (test fixtures may keep `whole` for legacy data — flag if found).

6. **Stale residue grep:**

```bash
grep -rn 'moistureContent\|qualityScore\|ir_mean_intensity\|MoistureWatch\|moisture_watch\|avg_quality_score' \
  web-dashboard/src/ api-server/app/
```

Expect zero hits.

7. **Calibration sanity:** put 50g of clear rice in the rig, photograph, run `python scripts/calibrate_mass_per_mm2.py photo.jpg --grams 50`. Computed `mass_per_mm²` should be within ~30% of the literature default `0.0022`. If wildly different, calibration constants in `constants.py` need updating.

---

## Critical Files

- `api-server/app/grading/inference.py` — class rename `whole→clear`
- `api-server/app/grading/features.py` — dimensional post-processing, area-to-grams helper
- `api-server/app/grading/grader.py` — brewers threshold, weight-% aggregator, drop foreign/paddy from grading
- `api-server/app/grading/constants.py` — NEW: per-class `MASS_PER_MM2`
- `api-server/app/grading/report.py` — surface `foreign_count`, `paddy_count`; drop `ir_mean_intensity`
- `api-server/scripts/calibrate_mass_per_mm2.py` — NEW: one-shot calibration helper
- `api-server/app/utils/metrics.py` — drop `qualityScore`, `moistureContent`; add `brewers`, `foreignCount`, `paddyCount`
- `api-server/app/schemas/analytics.py` — dynamic dict shapes
- `api-server/app/services/analytics_service.py` — dynamic param aggregation, drop moisture
- `web-dashboard/src/shared/api/contracts.ts` — mirror new shapes
- `web-dashboard/src/features/dashboard/mappers/dashboard.mappers.ts` — `buildRiceGradesData` reads `grade_counts`
- `web-dashboard/src/features/dashboard/hooks/useDashboardData.ts` — drop moisture watch
- `web-dashboard/src/features/analytics/utils/analytics.utils.tsx` — adapt mapper, surface PNS factors
- `web-dashboard/src/features/analytics/constants/analyticsCatalog.ts` — drop moisture/score, add brewers/damaged/red
- DELETE: `web-dashboard/src/features/dashboard/components/MoistureRiskPanel.tsx`
- `docs-and-architecture/api-server/grading-pipeline.md` — UPDATE/NEW
