# migrations/

Historical incremental migration files. **Do not apply these to a fresh database.**

For a fresh Supabase setup, use the consolidated files in the repo root:
- `../schema.sql` — full current-state schema, run once
- `../seed.sql` — reference data (regions), safe to re-run

## History

| File | What it did |
|------|-------------|
| `001_kiosk_grading_flow.sql` | Added `batch_name`, `status`, `callback_url` to `results`; `batch_number` to `result_images` |
| `004_edge_sessions.sql` | Created `edge_sessions` table |
| `005_rice_varieties.sql` | Created `rice_varieties` table |
| `006_drop_rice_varieties.sql` | Dropped `rice_varieties` (grain class auto-detected by inference) |
| `007_add_session_name.sql` | Added `session_name` to `edge_sessions` |
