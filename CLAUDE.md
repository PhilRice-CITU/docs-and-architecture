# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Central documentation and database schema repository for the Rice Vision system. Contains the authoritative database schema, seed data, and per-service architectural docs.

## Structure

```
docs-and-architecture/
├── schema.sql                        — Canonical Supabase schema (run this for fresh setup)
├── seed.sql                          — Reference data (17 Philippine regions)
├── migrations/                       — Dated forward-only migrations since the last schema.sql snapshot
├── README.md                         — Index of every file in this repo
└── api-server/
    ├── architecture.md               — Per-layer file map + request flow
    ├── database-schema.md            — ER diagram, table reference, Supabase setup
    ├── grading-pipeline.md           — How app/grading/ turns images into a graded result
    ├── metrics-contract.md           — Canonical metrics JSONB shape spec
    └── device-events-operations.md   — Event tiers and retention policies
```

## Usage

- **Fresh Supabase setup**: run `schema.sql`, then `seed.sql` in the Supabase SQL Editor, then apply anything newer from `migrations/` in date order.
- **Database schema changes**: add a new dated file under `migrations/` AND update `schema.sql` + `api-server/database-schema.md` in the same commit. `schema.sql` is the source of truth as of its last update.
- **Bug tracking**: lives in git issues or each repo's `docs/superpowers/plans/` — there is no central status file here anymore.

This repo has no build commands or tests — it is documentation only.
