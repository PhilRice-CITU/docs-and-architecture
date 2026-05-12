-- ============================================================
-- Rice Vision — Supabase Schema (current state)
-- Run this once in SQL Editor on a fresh Supabase project.
-- All statements use IF NOT EXISTS / OR REPLACE so it's safe
-- to re-run if something was partially applied.
-- After this: run seed.sql to insert reference data.
-- ============================================================


-- ============================================================
-- TRIGGER FUNCTION: auto-update updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- TABLE: regions
-- ============================================================
CREATE TABLE IF NOT EXISTS regions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    code        TEXT        NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER trg_regions_updated_at
    BEFORE UPDATE ON regions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- TABLE: users  (mirrors auth.users)
-- id must match the UUID from Supabase auth.users.
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
    id          UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    first_name  TEXT        NOT NULL,
    last_name   TEXT        NOT NULL,
    role        TEXT        NOT NULL CHECK (role IN ('superadmin', 'admin')),
    region_id   UUID        REFERENCES regions(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_region_id ON users(region_id);

CREATE OR REPLACE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- TABLE: devices
-- ============================================================
CREATE TABLE IF NOT EXISTS devices (
    id                        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name              TEXT        NOT NULL,
    status                    TEXT        NOT NULL DEFAULT 'active'
                                          CHECK (status IN ('active', 'maintenance', 'offline')),
    region_id                 UUID        NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
    cpu_percent               DOUBLE PRECISION,
    memory_percent            DOUBLE PRECISION,
    storage_percent           DOUBLE PRECISION,
    temperature_celsius       DOUBLE PRECISION,
    queue_depth               INTEGER,
    device_secret_hash        TEXT,
    device_secret_rotated_at  TIMESTAMPTZ,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_devices_region_id ON devices(region_id);

CREATE OR REPLACE TRIGGER trg_devices_updated_at
    BEFORE UPDATE ON devices
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- TABLE: results
-- ============================================================
CREATE TABLE IF NOT EXISTS results (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id     UUID        NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    session_id    TEXT,
    operator_name TEXT,
    rice_variety  TEXT,
    metrics       JSONB       NOT NULL DEFAULT '{}',
    batch_name    TEXT,
    status        TEXT        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending', 'processing', 'graded', 'failed', 'corrected')),
    grading_error TEXT,
    graded_at     TIMESTAMPTZ,
    stub_mode     BOOLEAN     NOT NULL DEFAULT FALSE,
    callback_url  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_results_device_id ON results(device_id);
CREATE INDEX IF NOT EXISTS idx_results_session_id ON results(session_id);

CREATE OR REPLACE TRIGGER trg_results_updated_at
    BEFORE UPDATE ON results
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- TABLE: result_images
-- ============================================================
CREATE TABLE IF NOT EXISTS result_images (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    result_id    UUID        NOT NULL REFERENCES results(id) ON DELETE CASCADE,
    camera_type  TEXT        NOT NULL CHECK (camera_type IN ('noir', 'led', 'annotated', 'annotated_ir')),
    storage_url  TEXT        NOT NULL,
    batch_number INTEGER     NOT NULL DEFAULT 1,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_result_images_result_id ON result_images(result_id);


-- ============================================================
-- TABLE: result_corrections (audit log for AI grading edits)
-- ============================================================
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


-- ============================================================
-- TABLE: device_commands
-- ============================================================
CREATE TABLE IF NOT EXISTS device_commands (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id    UUID        NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    command      TEXT        NOT NULL
                             CHECK (command IN ('capture', 'restart-app', 'restart-device', 'shutdown-device')),
    args         JSONB       NOT NULL DEFAULT '{}',
    status       TEXT        NOT NULL DEFAULT 'queued'
                             CHECK (status IN ('queued', 'processing', 'completed', 'failed', 'cancelled')),
    processed_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_device_commands_device_id_created_at
    ON device_commands(device_id, created_at DESC);


-- ============================================================
-- TABLE: device_events
-- ============================================================
CREATE TABLE IF NOT EXISTS device_events (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id  UUID        REFERENCES devices(id) ON DELETE SET NULL,
    level      TEXT        NOT NULL CHECK (level IN ('INFO', 'WARN', 'ERROR')),
    message    TEXT        NOT NULL,
    meta       JSONB       NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_device_events_created_at
    ON device_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_events_device_id_created_at
    ON device_events(device_id, created_at DESC);


-- ============================================================
-- TABLE: suggestions
-- ============================================================
CREATE TABLE IF NOT EXISTS suggestions (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    title      TEXT        NOT NULL,
    body       TEXT        NOT NULL,
    user_id    UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- TABLE: edge_sessions
-- Tracks a grading session on the Pi from capture → submit.
-- Batches are stored as JSONB: [{batch_number, ir_path, white_path, captured_at}]
-- ============================================================
CREATE TABLE IF NOT EXISTS edge_sessions (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id     UUID        NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    mode          TEXT        NOT NULL DEFAULT 'grade'
                              CHECK (mode IN ('grade', 'train')),
    operator_name TEXT        NOT NULL DEFAULT '',
    session_name  TEXT,
    rice_variety  TEXT,
    status        TEXT        NOT NULL DEFAULT 'capturing'
                              CHECK (status IN ('capturing', 'submitted', 'failed')),
    batches       JSONB       NOT NULL DEFAULT '[]'::JSONB,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS edge_sessions_device_id_idx ON edge_sessions(device_id);
CREATE INDEX IF NOT EXISTS edge_sessions_status_idx    ON edge_sessions(status);

CREATE OR REPLACE FUNCTION touch_edge_sessions_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS edge_sessions_updated_at ON edge_sessions;
CREATE TRIGGER edge_sessions_updated_at
    BEFORE UPDATE ON edge_sessions
    FOR EACH ROW EXECUTE FUNCTION touch_edge_sessions_updated_at();


-- ============================================================
-- AUTH TRIGGER: auto-create users row on Supabase sign-up
-- Safe to re-run (DROP + CREATE OR REPLACE).
-- ============================================================
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP FUNCTION IF EXISTS handle_new_auth_user();

CREATE OR REPLACE FUNCTION handle_new_auth_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.users (id, first_name, last_name, role)
    VALUES (
        NEW.id,
        COALESCE(
            NULLIF(NEW.raw_user_meta_data->>'first_name', ''),
            NULLIF(split_part(COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', ''), ' ', 1), ''),
            ''
        ),
        COALESCE(NULLIF(NEW.raw_user_meta_data->>'last_name', ''), ''),
        COALESCE(NULLIF(NEW.raw_user_meta_data->>'role', ''), 'admin')
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION handle_new_auth_user();


-- ============================================================
-- ROW LEVEL SECURITY
-- FastAPI uses service_role key (bypasses RLS).
-- RLS is a second layer for any direct PostgREST / anon access.
-- ============================================================
ALTER TABLE regions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE users           ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices         ENABLE ROW LEVEL SECURITY;
ALTER TABLE results         ENABLE ROW LEVEL SECURITY;
ALTER TABLE result_images   ENABLE ROW LEVEL SECURITY;
ALTER TABLE result_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_commands ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_events   ENABLE ROW LEVEL SECURITY;
ALTER TABLE suggestions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE edge_sessions   ENABLE ROW LEVEL SECURITY;

-- Users can read/insert/update their own profile row
CREATE POLICY IF NOT EXISTS "Users can read own profile"
    ON public.users FOR SELECT TO authenticated
    USING (auth.uid() = id);

CREATE POLICY IF NOT EXISTS "Users can insert own profile"
    ON public.users FOR INSERT TO authenticated
    WITH CHECK (auth.uid() = id);

CREATE POLICY IF NOT EXISTS "Users can update own profile"
    ON public.users FOR UPDATE TO authenticated
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);
