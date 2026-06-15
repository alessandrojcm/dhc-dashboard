# ADR 0001: Phoenix Takes Over Database Ownership

**Status:** Accepted  
**Date:** 2026-05-12  
**Deciders:** @alessandrojcm  
**Tags:** database, ecto, phoenix, migrations

## Context

The project uses Supabase-managed Postgres with 55 SQL migrations in `supabase/migrations/`. Supabase CLI owns the migration history via `supabase_migrations.schema_migrations`. Ecto (the Phoenix ORM) also manages migrations via its own `schema_migrations` table with a different schema (`version BIGINT` + `inserted_at` vs Supabase's `version VARCHAR` + `name` + `content`).

As business logic moves from SvelteKit + Deno edge functions to Phoenix, Ecto needs to:
1. Read and write to the existing database schema
2. Manage new schema changes going forward
3. Support Oban internal tables for background jobs

Two migration tracking systems cannot coexist cleanly on the same Postgres database due to conflicting `schema_migrations` table conventions.

## Decision

Phoenix (via Ecto) takes ownership of all database schema management:

- **Supabase migration history is frozen.** No new Supabase SQL migrations will be written. The existing 55 migrations remain in the repository for historical reference only.
- **Ecto baseline migrations** are written in clean Elixir code, organized by domain (~10 migration files), modeling the *current schema state* — not replaying history.
- **On the production database**, these baseline migrations are marked as already-run by inserting their version numbers into Ecto's `schema_migrations` table. The tables already exist; the migration files serve as documentation and as the schema builder for fresh environments.
- **All future schema changes** go through `mix ecto.gen.migration` and follow Ecto conventions.
- **The `auth.*` schema** (managed by Supabase Auth's GoTrue service) is modeled minimally in Ecto (just the columns we reference via foreign keys). The migration is marked as already-run on production since Supabase Auth manages `auth.*` internally.

## Consequences

- One migration system, one source of truth for schema state.
- Fresh dev/test/CI environments build the full schema from Ecto migrations in one pass.
- Supabase CLI's `db push` and `db diff` commands are no longer used.
- The baseline migration is large and should not be re-run on production. On fresh environments it creates everything from scratch.
- If Supabase Auth adds columns to `auth.*` in a future upgrade, those columns must be manually added to the Ecto schema definition for compile-time access in Phoenix code.

## Alternatives Considered

- **Keep both migration systems.** Supabase for DDL, Ecto configured with a different `migration_source` table. Rejected because it keeps the dual-ownership complexity alive indefinitely.
- **DDL dump as baseline.** `pg_dump --schema-only` piped into a single `execute/1` call. Rejected because a raw SQL dump is hard to review, diff, and maintain compared to structured Ecto code.
- **Replay all 55 migrations as individual Ecto migrations.** Rejected because the migration files predate the Phoenix project, have complex interdependencies, and replaying history adds risk for zero benefit.
