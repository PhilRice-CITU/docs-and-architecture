# Metrics Contract

**Last updated:** 2026-05-22

This document defines the canonical shape of the `metrics` JSONB column in the `results` table. This is the contract between the `app/grading/` inference pipeline (`build_payload`) and the `api-server` analytics layer.

---

## The Problem

`app/grading/report.py::build_payload` produces output with field names like `grade`, `total_grains_detected`, and `parameters.broken`. The dashboard analytics router reads camelCase field names like `qualityGrade`, `totalGrains`, and `chalkinessPercentage`. The two schemas are mapped in `app/utils/metrics.py`; this document defines the target shape and the mapping.

---

## Target `metrics` JSONB Schema

When `POST /scans` runs inference and stores a result, it must write this shape to `results.metrics`:

```json
{
  "qualityGrade": "Grade no. 2",
  "totalGrains": 112,
  "grainSizeClass": "long",
  "estimatedSizeClass": "long",
  "limitingFactor": "chalky",
  "brokenGrains": 8.93,
  "brewers": 0.12,
  "chalkinessPercentage": 6.25,
  "discolorationPercentage": 0.71,
  "damagedPercentage": 0.0,
  "redKernelPercentage": 1.4,
  "foreignCount": 0,
  "paddyCount": 1,
  "grainLengthMm": 6.8,
  "rawGrade": "Grade no. 2",
  "gradeOverridden": false,
  "parameters": { "broken": 8.93, "brewers": 0.12, "discolored": 0.71, "chalky": 6.25, "red": 1.4 },
  "perGrain": []
}
```

### Field Descriptions

| Field | Type | Source | Notes |
|-------|------|--------|-------|
| `qualityGrade` | `string` | `grade` from report verbatim | Raw PNS grade string; see "Grade naming" below |
| `totalGrains` | `int` | `total_grains_detected` from report | |
| `grainSizeClass` | `string` | `grain_size_class` from report | PNS class: `"short"\|"medium"\|"long"\|"extra_long"\|"mixed"` |
| `estimatedSizeClass` | `string` | `estimated_size_class` from report | Fallback estimate when measurement is unavailable |
| `limitingFactor` | `string` | `limiting_factor` from report | Parameter key that set the final grade |
| `brokenGrains` | `float` | `parameters.broken` | % by weight (0–100) |
| `brewers` | `float` | `parameters.brewers` | % by weight |
| `chalkinessPercentage` | `float` | `parameters.chalky` | % by weight |
| `discolorationPercentage` | `float` | `parameters.discolored` | % by weight |
| `damagedPercentage` | `float` | hardcoded `0.0` | Legacy field; always `0.0` — the `damaged` factor was consolidated into `discolored` |
| `redKernelPercentage` | `float` | `parameters.red` | % by weight |
| `foreignCount` | `int` | `foreign_count` from report | Count-only diagnostic; not used in PNS grading |
| `paddyCount` | `int` | `paddy_count` from report | Count-only diagnostic; not used in PNS grading |
| `grainLengthMm` | `float\|null` | Average `length_mm` of whole kernels in `perGrain` | Computed by `_avg_whole_kernel_length()`; `null` if no whole kernels measured |
| `rawGrade` | `string` | `grade` from report verbatim | Copy of `qualityGrade`; preserved for traceability |
| `gradeOverridden` | `bool` | Set by `POST /results/{id}/grade-override` | `true` when an admin has manually set the final grade |
| `parameters` | `object` | `parameters` dict from report | Keys: `broken`, `brewers`, `discolored`, `chalky`, `red` (all floats) |
| `perGrain` | `array` | `per_grain` from report | Per-grain detail objects; see shape below |

---

## Grade Naming

`qualityGrade` and `rawGrade` both carry the raw PNS/BAFS 290:2025 grade string verbatim — exactly one of:

- `Premium`
- `Grade no. 1`
- `Grade no. 2`
- `Grade no. 3`
- `Grade no. 4`
- `Grade no. 5`
- `Off-Grade`

There is no A/B/C/D letter-grade collapse anywhere in the pipeline. The dashboard renders these strings directly.

---

## `perGrain` Object Shape

Each element of `perGrain` is a per-grain detail dict as produced by the inference pipeline. The fields used by `_avg_whole_kernel_length()` to compute `grainLengthMm` are:

| Field | Type | Notes |
|-------|------|-------|
| `visual_class` | `string` | Grain appearance class: `"clear"\|"chalky"\|"discolored"\|"red"` (also falls back to `class_label` if present) |
| `dimensional_class` | `string` | `"whole"\|"broken"\|"brewers"` — only `"whole"` grains are averaged for `grainLengthMm` |
| `length_mm` | `float\|null` | Measured length in mm |

Additional per-grain fields (e.g., `bbox`, `confidence`, `width_mm`) are stored verbatim from the inference output for dashboard annotation overlay and correction recompute.

---

## Transformation Code (Python)

The actual implementation lives at `api-server/app/utils/metrics.py`:

```python
import statistics

PNS_GRADE_NAMES = (
    "Premium",
    "Grade no. 1",
    "Grade no. 2",
    "Grade no. 3",
    "Grade no. 4",
    "Grade no. 5",
    "Off-Grade",
)


def _avg_whole_kernel_length(per_grain: list[dict]) -> float | None:
    lengths = [
        g["length_mm"]
        for g in per_grain
        if g.get("visual_class", g.get("class_label")) in {"clear", "chalky", "discolored", "red"}
        and g.get("dimensional_class", "whole") == "whole"
        and g.get("length_mm") is not None
    ]
    return round(statistics.mean(lengths), 2) if lengths else None


def build_metrics(report: dict) -> dict:
    params = report.get("parameters", {})
    per_grain = report.get("per_grain", [])
    raw_grade = report.get("grade", "Off-Grade")

    return {
        "qualityGrade":            raw_grade,
        "totalGrains":             report.get("total_grains_detected", 0),
        "grainSizeClass":          report.get("grain_size_class", "mixed"),
        "estimatedSizeClass":      report.get("estimated_size_class", "unclassified"),
        "limitingFactor":          report.get("limiting_factor", ""),
        "brokenGrains":            params.get("broken", 0.0),
        "brewers":                 params.get("brewers", 0.0),
        "chalkinessPercentage":    params.get("chalky", 0.0),
        "discolorationPercentage": params.get("discolored", 0.0),
        "damagedPercentage":       0.0,
        "redKernelPercentage":     params.get("red", 0.0),
        "foreignCount":            int(report.get("foreign_count", 0)),
        "paddyCount":              int(report.get("paddy_count", 0)),
        "grainLengthMm":           _avg_whole_kernel_length(per_grain),
        "rawGrade":                raw_grade,
        "gradeOverridden":         False,
        "perGrain":                per_grain,
        "parameters":              params,
    }
```

---

## Where This Is Called

In `api-server/app/services/grading_service.py::grade_result` (background task), after the images are downloaded from Supabase Storage:

```python
# 1. Run inference + grading in-process
from ..grading import RiceGrader, build_payload
from ..grading.grader import grade_from_per_grain
from ..utils.metrics import build_metrics

grader = RiceGrader()  # or create_default_grader()
per_grain = grader.grade(raw_bytes, ir_bytes)
grade_result = grade_from_per_grain(per_grain)
report = build_payload(grade_result, per_grain)
metrics = build_metrics(report)

# 2. Insert result with populated metrics and status
supabase.table("results").insert({
    "id": result_id,
    "device_id": device_id,
    "operator_name": "",
    "rice_variety": None,
    "metrics": metrics,
    "status": "graded",
}).execute()
```

---

## Notes

- `damagedPercentage` is always `0.0`. The `damaged` defect factor was consolidated into `discolored`; the field is retained for backward compatibility with any existing stored records.
- `foreignCount` and `paddyCount` are raw counts used for diagnostic display only; they do not feed into PNS grading calculations.
- The `parameters` sub-object is stored verbatim for traceability and future re-grading without re-running inference. Keys are short names: `broken`, `brewers`, `discolored`, `chalky`, `red`.
- `rawGrade` preserves the PNS/BAFS label verbatim for display in the results table UI; it is always identical to `qualityGrade`.
- `grainLengthMm` is `null` when no whole kernels with valid length measurements are present in `perGrain`.
