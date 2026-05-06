-- Edge session state: replaces JSON files on the Pi with cloud-backed rows.
-- Sessions belong to a device, hold ordered batch metadata (image paths are Pi-local),
-- and transition: capturing → submitted | failed.

create table if not exists edge_sessions (
    id              uuid primary key default gen_random_uuid(),
    device_id       uuid not null references devices(id) on delete cascade,
    mode            text not null default 'grade' check (mode in ('grade', 'train')),
    operator_name   text not null default '',
    rice_variety    text,
    status          text not null default 'capturing' check (status in ('capturing', 'submitted', 'failed')),
    -- JSONB array of {batch_number, ir_path, white_path, captured_at}
    batches         jsonb not null default '[]'::jsonb,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

create index if not exists edge_sessions_device_id_idx on edge_sessions(device_id);
create index if not exists edge_sessions_status_idx on edge_sessions(status);

-- Auto-update updated_at
create or replace function touch_edge_sessions_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists edge_sessions_updated_at on edge_sessions;
create trigger edge_sessions_updated_at
    before update on edge_sessions
    for each row execute function touch_edge_sessions_updated_at();

-- RLS: devices can only see their own sessions (service role bypasses this)
alter table edge_sessions enable row level security;
