# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Central documentation and database schema repository for the Rice Vision system. Contains the authoritative database schema, seed data, and per-service architectural docs.

## Structure

```
docs-and-architecture/
├── schema.sql                        — Canonical Supabase schema (run this for fresh setup)
├── seed.sql                          — Reference data (17 Philippine regions)
├── PROJECT_INSTRUCTIONS.md           — Full system context for Claude.ai
├── SYSTEM_STATUS.md                  — Bug tracker and current system status
├── README.md                         — Project overview and repo status table
├── api-server/
│   ├── README.md                     — API server architecture notes
│   ├── database-schema.md            — Schema docs with ER diagram and setup guide
│   ├── metrics-contract.md           — Canonical metrics JSONB shape spec
│   └── device-events-operations.md   — Event tiers and retention policies
└── edge-client/
    └── edge.client.md                — Complete edge device coding spec
```

## Usage

- **Fresh Supabase setup**: run `schema.sql`, then `seed.sql` in the Supabase SQL Editor. No migration files — `schema.sql` is the complete current state.
- **Database schema changes**: update `schema.sql` AND `api-server/database-schema.md` together. `schema.sql` is the source of truth.
- **System bugs and status**: see `SYSTEM_STATUS.md`.

This repo has no build commands or tests — it is documentation only.
