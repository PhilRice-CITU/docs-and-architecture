CREATE TABLE rice_varieties (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL UNIQUE,
  grain_class   TEXT NOT NULL CHECK (grain_class IN ('long', 'medium', 'short')),
  avg_length_mm NUMERIC(5,2) NOT NULL,
  avg_width_mm  NUMERIC(5,2) NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
