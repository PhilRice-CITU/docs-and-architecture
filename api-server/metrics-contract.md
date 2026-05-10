# Metrics Contract

**Last updated:** 2026-04-22

This document defines the canonical shape of the `metrics` JSONB column in the `results` table. This is the contract between the `ai-vision-model` inference pipeline and the `api-server` analytics layer.

---

## The Problem

The `ai-vision-model` produces output with field names like `grade`, `total_grains_detected`, and `parameters.broken_kernels_pct`. The `api-server` analytics router reads field names like `qualityGrade`, `totalGrains`, and `chalkinessPercentage`. These two schemas have never been aligned — this document defines the target.

---

## Target `metrics` JSONB Schema

When `POST /scans` runs inference and stores a result, it must write this shape to `results.metrics`:

```json
{
  "qualityGrade": "A",
  "qualityScore": 87.5,
  "totalGrains": 112,
  "grainSizeClass": "long",
  "limitingFactor": "chalky_kernels_pct",
  "brokenGrains": 8.93,
  "chalkinessPercentage": 6.25,
  "discolorationPercentage": 0.71,
  "foreignMatter": 0.0,
  "moistureContent": null,
  "grainLengthMm": 6.8,
  "rawGrade": "Grade No. 2",
  "gradeOverridden": false,
  "perGrain": [
    {
      "grain_id": 0,
      "class_label": "whole_clear",
      "bbox": [120, 80, 180, 110],
      "confidence": 0.92,
      "length_mm": 6.8,
      "width_mm": 2.1,
      "grain_size_class": "long",
      "ir_mean_intensity": 130.2
    }
  ],
  "parameters": {
    "broken_kernels_pct": 8.93,
    "brewers_pct": 0.18,
    "damaged_kernels_pct": 0.89,
    "discolored_kernels_pct": 0.71,
    "chalky_kernels_pct": 6.25,
    "immature_kernels_pct": 0.45,
    "contrasting_types_pct": 0.0,
    "red_kernels_pct": 1.79,
    "foreign_matter_pct": 0.0
  }
}
```

### Field Descriptions

| Field | Type | Source | Notes |
|-------|------|--------|-------|
| `qualityGrade` | `"A"\|"B"\|"C"\|"D"` | Mapped from vision model `grade` | See grade mapping table below |
| `qualityScore` | `float\|null` | Computed (100 − weighted defect %) | Not yet implemented in vision model; store `null` for now |
| `totalGrains` | `int` | `total_grains_detected` from report | |
| `grainSizeClass` | `string` | `grain_size_class` from report | `"short"\|"medium"\|"long"\|"extra_long"\|"mixed"` |
| `limitingFactor` | `string` | `limiting_factor` from report | Parameter name with tightest passing margin |
| `brokenGrains` | `float` | `parameters.broken_kernels_pct` | Percentage (0–100) |
| `chalkinessPercentage` | `float` | `parameters.chalky_kernels_pct` | |
| `discolorationPercentage` | `float` | `parameters.discolored_kernels_pct` | |
| `foreignMatter` | `float` | `parameters.foreign_matter_pct` | |
| `moistureContent` | `float\|null` | Hardware sensor (not yet integrated) | Store `null` until moisture sensor is added |
| `grainLengthMm` | `float\|null` | Average `length_mm` across `whole_clear` grains in `per_grain` | Compute from per_grain list |
| `rawGrade` | `string` | `grade` from report verbatim | Preserve for traceability; e.g., `"Grade No. 2"` |
| `gradeOverridden` | `bool` | Set by `POST /results/{id}/grade-override` | `true` when an admin has manually set the final grade |
| `perGrain` | `array` | `per_grain` from report | Required for dashboard annotation overlay + correction recompute |
| `parameters` | `object` | `parameters` dict from report | Full parameter set for reference |

---

## Grade Mapping

The vision model outputs PNS/BAFS 290:2025 grade labels. Analytics uses A/B/C/D for charting.

| Vision Model `grade` | `qualityGrade` |
|----------------------|----------------|
| `"Premium"` | `"A"` |
| `"Grade No. 1"` | `"A"` |
| `"Grade No. 2"` | `"B"` |
| `"Grade No. 3"` | `"B"` |
| `"Grade No. 4"` | `"C"` |
| `"Grade No. 5"` | `"D"` |
| `"Off-Grade"` | `"D"` |

---

## Transformation Code (Python)

Add this function to `api-server/app/utils/metrics.py` (create if it doesn't exist):

```python
import statistics

GRADE_TO_LETTER = {
    "Premium":      "A",
    "Grade No. 1":  "A",
    "Grade No. 2":  "B",
    "Grade No. 3":  "B",
    "Grade No. 4":  "C",
    "Grade No. 5":  "D",
    "Off-Grade":    "D",
}

def build_metrics(report: dict) -> dict:
    """Transform ai-vision-model report payload into the canonical metrics JSONB shape."""
    params = report.get("parameters", {})
    per_grain = report.get("per_grain", [])

    whole_clear_lengths = [
        g["length_mm"]
        for g in per_grain
        if g.get("class_label") == "whole_clear" and g.get("length_mm") is not None
    ]
    avg_length = round(statistics.mean(whole_clear_lengths), 2) if whole_clear_lengths else None

    raw_grade = report.get("grade", "Off-Grade")

    return {
        "qualityGrade":          GRADE_TO_LETTER.get(raw_grade, "D"),
        "qualityScore":          None,  # not yet implemented
        "totalGrains":           report.get("total_grains_detected", 0),
        "grainSizeClass":        report.get("grain_size_class", "mixed"),
        "limitingFactor":        report.get("limiting_factor", ""),
        "brokenGrains":          params.get("broken_kernels_pct", 0.0),
        "chalkinessPercentage":  params.get("chalky_kernels_pct", 0.0),
        "discolorationPercentage": params.get("discolored_kernels_pct", 0.0),
        "foreignMatter":         params.get("foreign_matter_pct", 0.0),
        "moistureContent":       None,  # hardware sensor not yet integrated
        "grainLengthMm":         avg_length,
        "rawGrade":              raw_grade,
        "gradeOverridden":       False,
        "perGrain":              per_grain,
        "parameters":            params,
    }
```

---

## Where This Is Called

In `api-server/app/routers/scans.py`, after uploading images to Supabase Storage, the flow should be:

```python
# 1. Upload images (already implemented)
# 2. Run inference
from ..utils.metrics import build_metrics
# from ai_vision_model.inference import run_pipeline  (or call as subprocess)

report = run_pipeline(ir_image=ir_bytes, normal_image=raw_bytes)
metrics = build_metrics(report)

# 3. Insert result with populated metrics and status
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

- `moistureContent` is `null` until a moisture sensor is physically integrated into the rig. The analytics layer handles `null` values correctly (they are excluded from averages).
- `qualityScore` is reserved for a future weighted composite score. Store `null` until defined.
- The `parameters` sub-object is stored verbatim for traceability and future re-grading without re-running inference.
- `rawGrade` preserves the PNS/BAFS label for display in the results table UI.
