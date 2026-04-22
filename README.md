# docs-and-architecture

Central documentation and database reference for the Rice Vision system. No code runs here — this is the source of truth for schema, contracts, and system state.

## Contents

| File/Folder | Purpose |
|-------------|---------|
| [SYSTEM_STATUS.md](SYSTEM_STATUS.md) | Current implementation state of all 4 repos, confirmed bugs, fix priority order |
| [PROJECT_INSTRUCTIONS.md](PROJECT_INSTRUCTIONS.md) | Claude.ai project instructions — paste into project settings for full context in every chat |
| [api-server/database-schema.md](api-server/database-schema.md) | Supabase schema SQL, ER diagram, RLS setup, storage bucket guide |
| [api-server/metrics-contract.md](api-server/metrics-contract.md) | Canonical `metrics` JSONB schema bridging vision model output to analytics queries |
| [edge-client/edge.client.md](edge-client/edge.client.md) | Original edge client coding specification (partially outdated — see SYSTEM_STATUS.md Bug 10) |
| [migrations/001_kiosk_grading_flow.sql](migrations/001_kiosk_grading_flow.sql) | Adds `status`, `batch_name`, `callback_url` to results; `batch_number` to result_images |

## How to Use

- **Schema changes:** Update `api-server/database-schema.md` first, then run the SQL in Supabase Dashboard → SQL Editor. Add numbered migration files to `migrations/` for ALTER statements.
- **Bug tracking:** Check and update `SYSTEM_STATUS.md` when bugs are fixed.
- **Claude chat:** Copy `PROJECT_INSTRUCTIONS.md` content into your Claude.ai project's Instructions field.
