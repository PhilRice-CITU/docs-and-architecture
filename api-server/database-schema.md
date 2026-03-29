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
        timestamp updated_at
        timestamp created_at
    }

    RESULTS {
        uuid id PK
        uuid device_id FK
        text operator_name
        text rice_variety "Nullable (updated by admin)"
        jsonb metrics "AI computations (chalky, broken, etc.)"
        timestamp updated_at
        timestamp created_at
    }

    RESULT_IMAGES {
        uuid id PK
        uuid result_id FK
        text camera_type "ENUM: noir, led"
        text storage_url "Supabase Bucket path"
        timestamp created_at
    }

    REGIONS ||--o{ USERS : "assigned to"
    REGIONS ||--o{ DEVICES : "houses"
    DEVICES ||--o{ RESULTS : "processes"
    RESULTS ||--|{ RESULT_IMAGES : "contains up to 10"
```

---

## SQL vs Prisma — Which to Use

**Use Supabase SQL migrations (recommended for this project).**

| Factor | Supabase SQL Migrations | Prisma Migrations |
|---|---|---|
| Already using Supabase | Native fit | Requires separate connection setup |
| RLS (Row Level Security) | Full support in `.sql` files | Must be done outside Prisma anyway |
| Supabase Dashboard visibility | Schema shows up directly | Schema shows up directly |
| Auth integration (`auth.users`) | Direct `REFERENCES auth.users` | Requires raw SQL workaround |
| Complexity | Low — just SQL files | Higher — Prisma Client, schema.prisma, type generation |
| API server not yet built | No ORM needed yet | ORM is only useful once queries are written |

Prisma becomes worth it **if** you build a Node.js/Express or NestJS API server and want type-safe query builders. Even then, the database schema should be initialized through Supabase migrations first — you can layer Prisma on top later via `prisma db pull`.

---

## Migration SQL

File: `supabase/migrations/001_initial_schema.sql`

```sql
-- ============================================================
-- EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";


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
CREATE TABLE regions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    code        TEXT        NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_regions_updated_at
    BEFORE UPDATE ON regions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- TABLE: users  (mirrors auth.users)
-- ============================================================
-- NOTE: id must match the UUID from Supabase auth.users.
-- A trigger or edge function should insert a row here on signup.
CREATE TABLE users (
    id          UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    first_name  TEXT        NOT NULL,
    last_name   TEXT        NOT NULL,
    role        TEXT        NOT NULL CHECK (role IN ('superadmin', 'admin')),
    region_id   UUID        REFERENCES regions(id) ON DELETE SET NULL, -- nullable for superadmins
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_region_id ON users(region_id);

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- TABLE: devices
-- ============================================================
CREATE TABLE devices (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'active'
                             CHECK (status IN ('active', 'maintenance', 'offline')),
    region_id    UUID        NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_devices_region_id ON devices(region_id);

CREATE TRIGGER trg_devices_updated_at
    BEFORE UPDATE ON devices
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- TABLE: results
-- ============================================================
CREATE TABLE results (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id     UUID        NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    operator_name TEXT        NOT NULL,
    rice_variety  TEXT,       -- nullable; filled in by admin after the fact
    metrics       JSONB       NOT NULL DEFAULT '{}',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_results_device_id ON results(device_id);

CREATE TRIGGER trg_results_updated_at
    BEFORE UPDATE ON results
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- TABLE: result_images
-- ============================================================
CREATE TABLE result_images (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    result_id    UUID        NOT NULL REFERENCES results(id) ON DELETE CASCADE,
    camera_type  TEXT        NOT NULL CHECK (camera_type IN ('noir', 'led')),
    storage_url  TEXT        NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_result_images_result_id ON result_images(result_id);
```

---

## Supabase Setup Guide

### Prerequisites
- Node.js 18+
- Docker Desktop (running) — needed by Supabase CLI for local dev

---

### 1. Install Supabase CLI

```bash
brew install supabase/tap/supabase
```

Verify:
```bash
supabase --version
```

---

### 2. Initialize Supabase in the project

From the repo root (or `api-server/` if that's where your backend will live):

```bash
supabase init
```

This creates a `supabase/` folder with:
```
supabase/
  config.toml       ← local dev settings
  migrations/       ← SQL migration files go here
  seed.sql          ← optional seed data
```

---

### 3. Create the migration file

```bash
supabase migration new initial_schema
```

This creates `supabase/migrations/<timestamp>_initial_schema.sql`.

Paste the SQL from the section above into that file.

---

### 4. Option A — Apply to local Supabase (for development)

Start local Supabase stack (requires Docker):
```bash
supabase start
```

Apply migrations:
```bash
supabase db reset
# or incrementally:
supabase migration up
```

Local Studio dashboard opens at **http://localhost:54323** — you can inspect your schema there.

Local DB connection string:
```
postgresql://postgres:postgres@localhost:54322/postgres
```

---

### 5. Option B — Apply directly to your hosted Supabase project

#### Link your project first:
```bash
supabase login
supabase link --project-ref <your-project-ref>
```

Your project ref is in the Supabase dashboard URL:
`https://supabase.com/dashboard/project/<project-ref>`

#### Push the migration:
```bash
supabase db push
```

This runs all pending migrations in `supabase/migrations/` against your hosted database.

> Alternatively, you can open the **SQL Editor** in the Supabase dashboard and run the migration SQL directly — useful for a one-time setup on a thesis project.

---

### 6. Auto-create user profile on signup (Edge Function trigger)

Since `users.id` references `auth.users(id)`, you need to insert a row into `users` when someone signs up. Add this as a **Database Trigger** via SQL:

```sql
-- Run this in Supabase SQL Editor or add as a second migration file
CREATE OR REPLACE FUNCTION handle_new_auth_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO users (id, first_name, last_name, role)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
        COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
        COALESCE(NEW.raw_user_meta_data->>'role', 'admin')
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION handle_new_auth_user();
```

When using `supabase.auth.signUp()` in the frontend, pass metadata:
```ts
supabase.auth.signUp({
  email,
  password,
  options: {
    data: { first_name, last_name, role: 'admin' }
  }
})
```

---

### 7. Environment variables

Your web dashboard already expects these in `.env`:
```env
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon-key>
```

Both are found under **Project Settings → API** in the Supabase dashboard.

---

### 8. Row Level Security (RLS) — recommended next step

Enable RLS on all tables to ensure users can only access data scoped to their region:

```sql
ALTER TABLE regions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE users        ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices      ENABLE ROW LEVEL SECURITY;
ALTER TABLE results      ENABLE ROW LEVEL SECURITY;
ALTER TABLE result_images ENABLE ROW LEVEL SECURITY;
```

Define policies per table based on the `role` and `region_id` in `users`. This is the core security layer for a multi-tenant setup like this one.
