# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Central documentation and database schema repository for the Rice Vision system. Contains the authoritative database schema, migration SQL, and per-service architectural docs.

## Structure

```
docs-and-architecture/
├── api-server/
│   ├── README.md              — API server architecture notes
│   ├── database-schema.md     — Authoritative Supabase schema (source of truth)
│   └── edge.client.md         — Edge client integration spec
├── edge-client/               — Edge client architecture docs
└── migrations/
    └── 001_kiosk_grading_flow.sql — Database migration SQL
```

## Usage

- **Database schema changes**: update `api-server/database-schema.md` first, then apply via Supabase SQL Editor or as a numbered migration in `migrations/`.
- **Migration naming**: `NNN_short_description.sql` (zero-padded 3-digit number).
- **Migrations run in**: Supabase SQL Editor, or schedule repeating ones via `pg_cron`.

This repo has no build commands or tests — it is documentation only.
