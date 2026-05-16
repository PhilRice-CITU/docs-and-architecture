# docs-and-architecture

Central documentation and database reference for the Rice Vision system. No code runs here — this is the source of truth for schema, contracts, and per-service architecture.

## Contents

| File/Folder | Purpose |
|-------------|---------|
| [schema.sql](schema.sql) | Canonical Supabase schema — run on a fresh project (all tables, triggers, RLS) |
| [seed.sql](seed.sql) | Reference data — 17 PSA-defined Philippine regions |
| [migrations/](migrations/) | Dated forward-only SQL migrations applied since the last `schema.sql` snapshot |
| [api-server/architecture.md](api-server/architecture.md) | Per-layer file map (routers → services → repositories) and request flow |
| [api-server/database-schema.md](api-server/database-schema.md) | ER diagram, table reference, Supabase setup guide |
| [api-server/grading-pipeline.md](api-server/grading-pipeline.md) | How `app/grading/` turns raw + IR images into a graded result |
| [api-server/metrics-contract.md](api-server/metrics-contract.md) | Canonical `metrics` JSONB schema bridging vision-model output to analytics queries |
| [api-server/device-events-operations.md](api-server/device-events-operations.md) | Device event tiers, retention policies, archiving strategy |

## How to Use

- **Fresh Supabase setup:** Run `schema.sql` in Supabase Dashboard → SQL Editor, then run `seed.sql`. Then apply anything newer from `migrations/` in date order. `schema.sql` is the source of truth as of its commit date.
- **Schema changes:** Add a new dated file under `migrations/` AND update `schema.sql` + `api-server/database-schema.md` in the same commit.
- **Bug tracking:** Track in git issues or in `<repo>/docs/superpowers/plans/`. There is no central status file in this repo anymore.
