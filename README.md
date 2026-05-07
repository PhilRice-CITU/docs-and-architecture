# docs-and-architecture

Central documentation and database reference for the Rice Vision system. No code runs here — this is the source of truth for schema, contracts, and system state.

## Contents

| File/Folder | Purpose |
|-------------|---------|
| [schema.sql](schema.sql) | Canonical Supabase schema — run this on a fresh project (all tables, triggers, RLS) |
| [seed.sql](seed.sql) | Reference data — 17 PSA-defined Philippine regions |
| [SYSTEM_STATUS.md](SYSTEM_STATUS.md) | Current implementation state of all 4 repos, confirmed bugs, fix priority order |
| [PROJECT_INSTRUCTIONS.md](PROJECT_INSTRUCTIONS.md) | Claude.ai project instructions — paste into project settings for full context in every chat |
| [api-server/database-schema.md](api-server/database-schema.md) | ER diagram, metrics JSONB shape, Supabase setup guide |
| [api-server/metrics-contract.md](api-server/metrics-contract.md) | Canonical `metrics` JSONB schema bridging vision model output to analytics queries |
| [api-server/device-events-operations.md](api-server/device-events-operations.md) | Device event tiers, retention policies, archiving strategy |
| [edge-client/edge.client.md](edge-client/edge.client.md) | Complete edge client coding specification (Flask, shell, Electron) |

## How to Use

- **Fresh Supabase setup:** Run `schema.sql` in Supabase Dashboard → SQL Editor, then run `seed.sql`. That's it — no migration files.
- **Schema changes:** Update `schema.sql` and `api-server/database-schema.md` together. `schema.sql` is the source of truth.
- **Bug tracking:** Check and update `SYSTEM_STATUS.md` when bugs are fixed.
- **Claude chat:** Copy `PROJECT_INSTRUCTIONS.md` content into your Claude.ai project's Instructions field.
