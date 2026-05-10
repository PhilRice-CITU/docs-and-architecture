-- Migration: wire AI grading pipeline + annotation corrections
-- Apply to existing databases that pre-date schema.sql changes from 2026-05-09.
-- Idempotent: safe to re-run.

-- 1. results: add grading lifecycle columns + extend status check
ALTER TABLE results ADD COLUMN IF NOT EXISTS grading_error TEXT;
ALTER TABLE results ADD COLUMN IF NOT EXISTS graded_at     TIMESTAMPTZ;
ALTER TABLE results ADD COLUMN IF NOT EXISTS stub_mode     BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE results DROP CONSTRAINT IF EXISTS results_status_check;
ALTER TABLE results ADD  CONSTRAINT results_status_check
    CHECK (status IN ('pending', 'processing', 'graded', 'failed', 'corrected'));

-- 2. result_images: allow 'annotated' camera_type for the rendered overlay
ALTER TABLE result_images DROP CONSTRAINT IF EXISTS result_images_camera_type_check;
ALTER TABLE result_images ADD  CONSTRAINT result_images_camera_type_check
    CHECK (camera_type IN ('noir', 'led', 'annotated'));

-- 3. result_corrections: audit log for AI grading edits
CREATE TABLE IF NOT EXISTS result_corrections (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    result_id       UUID        NOT NULL REFERENCES results(id) ON DELETE CASCADE,
    corrected_by    UUID        NOT NULL REFERENCES users(id),
    correction_type TEXT        NOT NULL CHECK (correction_type IN ('grain_class', 'grade_override')),
    payload         JSONB       NOT NULL,
    metrics_before  JSONB       NOT NULL,
    metrics_after   JSONB       NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_result_corrections_result_id ON result_corrections(result_id);

ALTER TABLE result_corrections ENABLE ROW LEVEL SECURITY;
