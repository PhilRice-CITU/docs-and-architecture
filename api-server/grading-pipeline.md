# Grading Pipeline (PNS/BAFS 290:2025)

This document describes how a scan flows through the grader, what PNS factors
are applied, how dual-camera fusion works, and how the calibration constants
were derived.

## Pipeline overview

```
edge POST /scans (raw + ir)
    -> scan_service.ingest_scan
    -> grading_service.grade_result (background task)
        -> RiceGrader.grade(normal_image, ir_image)
            -> normal_model.predict(white-LED image)   [YOLOv11n segmentation]
            -> ir_model.predict(NIR image)             [YOLOv11n segmentation]
            -> _extract_detections (per model)
            -> _merge_detections                       [IR.chalky overrides]
            -> apply_dimensional_post_processing       [PNS broken / brewers]
            -> summarize_weight_percentages            [grading uses this]
            -> grade_supported_factors                 [thresholds -> grade]
        -> build_payload + build_metrics
    -> results_repo.mark_graded (writes metrics jsonb)
```

## Class taxonomy

The two YOLO models share these labels (data.yaml). Inference uses identical
strings:

| Class        | Source model       | PNS interpretation                       |
|--------------|--------------------|------------------------------------------|
| `clear`      | white-LED + IR     | No defect; reference for size/length     |
| `chalky`     | IR (authoritative) | PNS chalky kernel                        |
| `broken`     | white-LED + IR     | Reclassified post-detection by length    |
| `brewers`    | post-processing    | Reclassified post-detection by min-axis  |
| `damaged`    | white-LED          | Formerly a separate PNS class; consolidated into `discolored` (commit 906ddb7, 2026-05-15) — detections are now counted under `discolored` |
| `discolored` | white-LED          | PNS discolored kernel (incl. fermented and formerly-damaged kernels) |
| `red`        | white-LED          | PNS red kernel                           |
| `foreign`    | white-LED + IR     | Non-rice matter; count-only diagnostic   |
| `paddy`      | white-LED          | Hulled grains; count-only diagnostic     |

## Two-model fusion

Two YOLO segmentation models run on each scan: `normal` (white LED) and `ir`
(NIR). The IR camera resolves chalky grains better; the white-LED camera
resolves color-based defects (discolored, red) better.

Fusion is implemented in `_merge_detections`
(`api-server/app/grading/inference.py`):

1. **Drop normal-model `chalky`.** Any `chalky` detection from the white-LED
   model is discarded outright; IR is the chalky authority.
2. **Match IR `chalky` against the normal pool.** For each IR `chalky`
   detection, find the best normal-model detection by IoU >= 0.25 OR center
   distance <= 0.03 (in normalized coords). The matched normal detection is
   removed and the IR `chalky` takes its place.
3. **Append unmatched IR `chalky`.** If an IR `chalky` has no normal
   counterpart it is added as a new grain.
4. **Append remaining normal detections.** All non-chalky white-LED detections
   pass through unchanged (white-LED is authoritative for `discolored`, `red`,
   `paddy`, `foreign`).

The IR model is trained only on `clear` / `chalky` / `foreign`; non-chalky IR
detections are not propagated by the fusion logic.

Override thresholds (`override_iou_threshold`, `override_center_threshold`)
are constructor arguments on `RiceGrader`.

## Dimensional post-processing (PNS sec. 3.1, 3.2)

After fusion and before any aggregation, `apply_dimensional_post_processing`
(`api-server/app/grading/features.py`) walks every detection and reclassifies
rice-class grains:

- **Brewers** (PNS sec. 3.1): both `length_mm < 1.4` AND `width_mm < 1.4`. The
  length-and-width form maps to a 1.4mm round sieve geometry.
- **Broken** (PNS sec. 3.2): `length_mm < 0.75 * mean(clear_length_mm)`. The
  reference is computed per scan from the `clear` detections. Fallbacks:
  - No `clear` grains: median length of all rice-class detections.
  - No rice-class detections: indica long-grain default `6.8 mm` (Annex C).

Brewers test runs first (more restrictive). Foreign and paddy are never
reclassified. Already-`broken` labels are left as-is.

## Calibrated weight-%

PNS thresholds are by mass (% by weight) but a top-down camera measures area.
We bridge the gap with per-class mass-per-mm^2 constants and aggregate by mass.

`summarize_weight_percentages` (`api-server/app/grading/grader.py`):

```
mass_g = area_px * MM2_PER_PX2 * MASS_PER_MM2[class]
factor_pct = (mass_by_class / total_rice_mass) * 100
```

- `MM2_PER_PX2` is derived from a 23 mm reference coin measured at 1257.04 px
  diameter (`PX_PER_MM = 54.6539`).
- `MASS_PER_MM2[class]` lives in `api-server/app/grading/constants.py`. Defaults
  are literature-derived for Philippine indica long-grain rice (1000-grain
  weight ~21 g, density ~1.45 g/cm^3, mean grain area ~9.6 mm^2), giving
  ~0.0022 g/mm^2 for every rice class.
- For a real device, recalibrate using
  `api-server/scripts/calibrate_mass_per_mm2.py`: weigh a known mass of pure
  rice, photograph it in the rig, run the script, paste the printed value into
  `constants.py`.

Foreign and paddy have no mass-per-mm^2 entry and are excluded from the weight
aggregation entirely.

`summarize_area_percentages` is still emitted in the report under
`area_percentages_diagnostic` for QA, but grading is driven by weight.

## Graded vs ungraded factors

| PNS factor        | Visually graded? | Why                                                                          |
|-------------------|------------------|------------------------------------------------------------------------------|
| broken            | yes (weight-%)   | Length-rule reclassification + weight aggregation                            |
| brewers           | yes (weight-%)   | Min-axis reclassification + weight aggregation                               |
| damaged           | no (removed)     | Consolidated into `discolored` (commit 906ddb7, 2026-05-15); no longer a separate grading factor |
| discolored        | yes (weight-%)   | Direct YOLO class (absorbs formerly-damaged kernels)                         |
| chalky            | yes (weight-%)   | IR-authoritative class                                                       |
| red               | yes (weight-%)   | Direct YOLO class                                                            |
| foreign           | no (count)       | PNS unit is % by weight; density of sand/husk wildly varies. `foreignCount`  |
| paddy             | no (count)       | PNS unit is count per 1000g; needs a real scale. `paddyCount`                |
| immature          | no               | No model class                                                               |
| contrasting types | no               | Variety detection out of scope                                               |
| degree of milling | no               | Alcohol-alkali staining (Annex A), not vision                                |

## Grade thresholds (PNS Table 2)

`GRADE_THRESHOLDS` in `api-server/app/grading/grader.py` encodes Table 2 (max %
by weight) for each grade:

| Grade       | broken | brewers | discolored | chalky | red |
|-------------|--------|---------|------------|--------|-----|
| Premium     | 5.0    | 0.10    | 0.5        | 4.0    | 1.0 |
| Grade no. 1 | 10.0   | 0.20    | 0.7        | 5.0    | 2.0 |
| Grade no. 2 | 15.0   | 0.40    | 1.0        | 7.0    | 4.0 |
| Grade no. 3 | 25.0   | 0.60    | 3.0        | 9.0    | 5.0 |
| Grade no. 4 | 35.0   | 1.00    | 5.0        | 12.0   | 6.0 |
| Grade no. 5 | 45.0   | 2.00    | 8.0        | 15.0   | 7.0 |

Grading rule (`grade_supported_factors`): for each factor pick the strictest
grade whose threshold is not exceeded; the overall grade is the strictest
across all factors. If any factor exceeds Grade no. 5, the result is
`Off-Grade`. The factor that determined the overall grade is reported as
`limitingFactor`.

## Grade naming

`qualityGrade` and `rawGrade` carry the raw PNS grade string verbatim:

- `Premium`
- `Grade no. 1`
- `Grade no. 2`
- `Grade no. 3`
- `Grade no. 4`
- `Grade no. 5`
- `Off-Grade`

There is **no A/B/C/D collapse**. The dashboard renders short forms via
`pnsGradeShortLabel` (`web-dashboard/src/shared/lib/pnsGrade.ts`):

- `Premium` -> `Premium`
- `Grade no. 1` -> `1`
- `Grade no. 2` -> `2`
- `Grade no. 3` -> `3`
- `Grade no. 4` -> `4`
- `Grade no. 5` -> `5`
- `Off-Grade` -> `Off-Grade`

`PNS_GRADE_NAMES` in `api-server/app/utils/metrics.py` is the canonical list
used for grade-override validation in `annotation_service`.

## Removed fields

The following always-null/zero fields were dropped during the PNS alignment
pass:

- `qualityScore` (never computed)
- `moistureContent` (vision system has no moisture sensor)
- `ir_mean_intensity` per-grain field (placeholder, never extracted)
- `GRADE_TO_LETTER` mapping (no A/B/C/D collapse anymore)

## Analytics shape

`AnalyticsSummary`, `AnalyticsTrendPoint`, and `DashboardSummary` use dynamic
dict shapes:

- `grade_counts: dict[str, int]` keyed by raw PNS grade name
- `factor_averages: dict[str, float | None]` keyed by parameter name

This means new PNS factors propagate through analytics without a schema
migration. The frontend reads via `factor_averages.broken`,
`factor_averages.brewers`, etc., and `grade_counts.Premium`,
`grade_counts['Grade no. 1']`, etc.
