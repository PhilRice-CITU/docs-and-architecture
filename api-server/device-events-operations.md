# Device Events Operations

This guide documents the long-term event strategy used by the API server.

## Event Tiers

- Warm audit: only meaningful events are persisted to `device_events`.
- Cold archive: bulk raw logs are exported as NDJSON/GZIP to object storage.

## Warm Audit Rules

Persist events when:

- `level` is `WARN` or `ERROR`
- event clearly reflects command lifecycle/state transitions
- `meta.persist_event` is explicitly set to `true`

Do not persist noisy informational logs by default.

## Retention SQL

Use the policy in [api-server/tools/device_events_retention.sql](../../api-server/tools/device_events_retention.sql).

Recommended retention windows:

- INFO: 7-14 days
- WARN/ERROR: 60-180 days

Current policy is 14 days for INFO and 120 days for WARN/ERROR.

## Optional Scheduling (Supabase pg_cron) — NOT currently implemented

> **Note:** The `cron.schedule()` job below is a **suggested approach only**.
> It has **not** been created in the database — there is no pg_cron job in
> the api-server, migrations, or schema at this time. If you want automated
> retention, this is the recommended starting point.

```sql
-- Suggested: run daily at 02:10 UTC (not yet implemented)
select cron.schedule(
  'device_events_retention_daily',
  '10 2 * * *',
  $$
  DELETE FROM public.device_events
  WHERE level = 'INFO'
    AND created_at < NOW() - INTERVAL '14 days';

  DELETE FROM public.device_events
  WHERE level IN ('WARN', 'ERROR')
    AND created_at < NOW() - INTERVAL '120 days';
  $$
);
```

## Cold Archive Job

Use `api-server/tools/archive_device_events.py` on a daily schedule to export the previous window to Supabase Storage as compressed NDJSON.

Example run:

```bash
python tools/archive_device_events.py
```

Environment variables:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `DEVICE_EVENT_ARCHIVE_BUCKET` (default `device-event-archives`)
- `DEVICE_EVENT_ARCHIVE_DAYS` (default `1`)
- `DEVICE_EVENT_ARCHIVE_BATCH_SIZE` (default `1000`)

## Optional Next Step: Monthly Partitioning

When row volume grows significantly, partition `device_events` by month on `created_at` and keep the same retention job. This keeps list queries and deletes efficient while preserving the API contract.
