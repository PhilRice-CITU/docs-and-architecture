# Database Schema

## ER Diagram

```mermaid
erDiagram
    REGIONS {
        uuid id PK
        text name "e.g., Central Visayas"
        text code "e.g., cebu"
        timestamp updated_at
        timestamp created_at
    }

    USERS {
        uuid id PK "Matches Supabase auth.users"
        text first_name
        text last_name
        text role "ENUM: superadmin, admin"
        uuid region_id FK "Nullable for superadmins"
        timestamp updated_at
        timestamp created_at
    }

    DEVICES {
        uuid id PK "Hardware API Key"
        text display_name "e.g., cebu-112"
        text status "ENUM: active, maintenance, offline"
        uuid region_id FK
        float cpu_percent "Nullable edge telemetry"
        float memory_percent "Nullable edge telemetry"
        float storage_percent "Nullable edge telemetry"
        float temperature_celsius "Nullable edge telemetry"
        int queue_depth "Nullable edge telemetry"
        timestamp updated_at
        timestamp created_at
    }

    RESULTS {
        uuid id PK
        uuid device_id FK
        text session_id "Nullable — links to edge_sessions.id"
        text operator_name "Nullable"
        text rice_variety "Nullable"
        jsonb metrics "AI computations (chalky, broken, etc.)"
        text batch_name "Nullable"
        text status "ENUM: pending, processing, graded, failed, corrected"
        text grading_error "Nullable"
        timestamp graded_at "Nullable"
        bool stub_mode "True if model file missing (synthetic data)"
        text callback_url "Nullable"
        timestamp updated_at
        timestamp created_at
    }

    RESULT_IMAGES {
        uuid id PK
        uuid result_id FK
        text camera_type "ENUM: noir, led, annotated, annotated_ir"
        text storage_url "Supabase Bucket path"
        int batch_number "Default 1"
        timestamp created_at
    }

    EDGE_SESSIONS {
        uuid id PK
        uuid device_id FK
        text mode "ENUM: grade, train"
        text operator_name
        text session_name "Nullable"
        text rice_variety "Nullable — varietyname_YYYYMMDD_HHmmss"
        text status "ENUM: capturing, submitted, failed"
        jsonb batches "Array of {batch_number, ir_path, white_path, captured_at}"
        timestamp updated_at
        timestamp created_at
    }

    DEVICE_COMMANDS {
        uuid id PK
        uuid device_id FK
        text command "ENUM: capture, restart-app, restart-device, shutdown-device"
        jsonb args
        text status "ENUM: queued, processing, completed, failed, cancelled"
        timestamp processed_at
        timestamp created_at
    }

    DEVICE_EVENTS {
        uuid id PK
        uuid device_id FK "Nullable for system-wide events"
        text level "ENUM: INFO, WARN, ERROR"
        text message
        jsonb meta
        timestamp created_at
    }

    RESULT_CORRECTIONS {
        uuid id PK
        uuid result_id FK
        uuid corrected_by FK "users.id"
        text correction_type "ENUM: grain_class, grade_override"
        jsonb payload
        jsonb metrics_before
        jsonb metrics_after
        timestamp created_at
    }

    REGIONS ||--o{ USERS : "assigned to"
    REGIONS ||--o{ DEVICES : "houses"
    DEVICES ||--o{ RESULTS : "processes"
    RESULTS ||--|{ RESULT_IMAGES : "contains up to 10"
    RESULTS ||--o{ RESULT_CORRECTIONS : "audit trail"
    DEVICES ||--o{ DEVICE_COMMANDS : "receives commands"
    DEVICES ||--o{ DEVICE_EVENTS : "emits events"
    DEVICES ||--o{ EDGE_SESSIONS : "owns"
```

---

## `results.metrics` JSONB Shape

The `metrics` column stores the output of the AI inference pipeline after it has been transformed into the canonical analytics schema. Do **not** store the raw `ai-vision-model` report payload directly — use the transformation function in `app/utils/metrics.py`.

See [metrics-contract.md](./metrics-contract.md) for the full field spec, grade mapping table, and transformation code.

**Quick reference — expected keys:**

| Key | Type | Example |
|-----|------|---------|
| `qualityGrade` | `"A"\|"B"\|"C"\|"D"` | `"B"` |
| `rawGrade` | string | `"Grade No. 2"` |
| `totalGrains` | int | `112` |
| `grainSizeClass` | string | `"long"` |
| `limitingFactor` | string | `"chalky_kernels_pct"` |
| `brokenGrains` | float | `8.93` |
| `chalkinessPercentage` | float | `6.25` |
| `discolorationPercentage` | float | `0.71` |
| `foreignMatter` | float | `0.0` |
| `moistureContent` | float\|null | `null` (sensor not yet integrated) |
| `grainLengthMm` | float\|null | `6.8` |
| `qualityScore` | float\|null | `null` (not yet implemented) |
| `parameters` | object | Full PNS/BAFS parameter set |

---

## Approach: SQL via Supabase Dashboard

No CLI, no Docker, nothing installed locally. All schema setup is done through the **Supabase SQL Editor** online.

**Source of truth**: [`../schema.sql`](../schema.sql) — single consolidated file, current state.  
**Reference data**: [`../seed.sql`](../seed.sql) — regions seed, safe to re-run.

---

## Supabase Dashboard Setup Guide

No CLI, no Docker. Everything runs in the browser.

---

### 1. Create a Supabase project

1. Go to [supabase.com](https://supabase.com) and sign in (or create a free account)
2. Click **New project**
3. Fill in:
   - **Name** — e.g., `rice-thesis`
   - **Database password** — save this somewhere safe
   - **Region** — pick the closest to the Philippines (Singapore is the nearest)
4. Wait ~1 minute for provisioning

---

### 2. Get your credentials

Go to **Project Settings → API** and copy:

| Variable                    | Where to find it                                            |
| --------------------------- | ----------------------------------------------------------- |
| `VITE_SUPABASE_URL`         | Project URL (e.g., `https://xxxx.supabase.co`)              |
| `VITE_SUPABASE_ANON_KEY`    | `anon` `public` key                                         |
| `SUPABASE_SERVICE_ROLE_KEY` | `service_role` key (for FastAPI backend only — keep secret) |

Add to `web-dashboard/.env`:

```env
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon-key>
```

Add to `api-server/.env`:

```env
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<service-role-key>
SUPABASE_JWT_SECRET=<jwt-secret>
```

The JWT secret is under **Project Settings → API → JWT Settings**.

---

### 3. Run `schema.sql`

Open **SQL Editor → New query**, paste the full contents of [`../schema.sql`](../schema.sql), click **Run**.

This creates all tables, indexes, triggers (including `updated_at` auto-update and the Supabase auth user sync trigger), enables RLS on all tables, and adds RLS policies for the `users` table — everything in one shot. All statements use `IF NOT EXISTS` / `OR REPLACE` so it's safe to re-run.

> **If you see "Database error saving new user" on sign-up**, re-run `schema.sql` — the `DROP TRIGGER IF EXISTS` / `DROP FUNCTION IF EXISTS` guards make it idempotent.

When calling `supabase.auth.signUp()` from the frontend, pass metadata so the auth trigger can populate the profile:

```ts
supabase.auth.signUp({
  email,
  password,
  options: {
    data: { first_name, last_name, role: "admin" },
  },
});
```

---

### 4. Run `seed.sql`

Open a **new query**, paste [`../seed.sql`](../seed.sql), click **Run**. Inserts the 17 PSA-defined Philippine regions. Safe to re-run.

---

### 5. Create a Storage bucket for images

1. Go to **Storage → New bucket**
2. Name it `result-images`
3. Set it to **Private** (FastAPI handles all uploads using the service role key — no public access needed)

The `storage_url` column in `result_images` stores the path within this bucket (e.g., `results/<result_id>/noir.jpg`).
