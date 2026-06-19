-- bridge.sql
--
-- One-shot bridge to adopt Ecto migrations on an existing Supabase-managed DB.
--
-- Run ONCE before the first Phoenix/Fly `ecto.migrate` against a production
-- Supabase database whose schema was created by the (now-frozen) Supabase SQL
-- migrations in `supabase/migrations/`. See AGENTS.md → "MIGRATION NOTES".
--
-- Why this exists
-- ---------------
-- The baseline Ecto migrations in `apps/phoenix/priv/repo/migrations/`
-- (`20260512000002` … `20260512000011`) recreate schema objects that the
-- Supabase SQL migrations already created — enums, tables, indexes. On a DB
-- Phoenix has never migrated, `schema_migrations` is empty, so `ecto.migrate`
-- would try to `CREATE TYPE` / `CREATE TABLE` things that already exist and
-- fail. This script marks those baseline versions as already applied so Ecto
-- skips them, while leaving the cutover migrations pending so Phoenix runs
-- them itself.
--
-- What gets bridged (marked applied, NOT executed)
-- -----------------------------------------------
--   20260512000002_create_extensions_and_enums
--   20260512000003_create_waitlist
--   20260512000004_create_users_and_roles
--   20260512000005_create_member_profiles
--   20260512000006_create_settings
--   20260512000007_create_club_activities
--   20260512000008_create_registrations_and_refunds
--   20260512000009_create_invitations
--   20260512000010_create_inventory
--   20260512000011_create_notifications
--
-- These map 1:1 to objects the Supabase SQL migrations already created.
--
-- What is left pending (Phoenix will run it via `ecto.migrate`)
-- -------------------------------------------------------------
--   20260512000001_create_oban_jobs        — Oban schema (Phoenix-introduced;
--                                            Supabase migrations never created
--                                            Oban tables — they used pg_cron).
--   20260611224011_remove_stripe_sync_pg_cron — unschedules the legacy
--                                            pg_cron job now replaced by the
--                                            Oban stripe_sync worker.
--
-- Idempotency
-- -----------
-- `ON CONFLICT DO NOTHING` makes this safe to re-run. Only the Ecto-shaped
-- `public.schema_migrations` is touched; the Supabase-managed
-- `supabase_migrations.schema_migrations` is left alone.
--
-- Usage
-- -----
--   psql "$DATABASE_URL" -f scripts/bridge.sql
--
-- Then run the Phoenix migration to apply only the pending cutover:
--
--   mix ecto.migrate

BEGIN;

-- Ensure Ecto's migration bookkeeping table exists. Phoenix creates it on
-- first migrate; we create it here in case the DB has only ever seen
-- Supabase migrations (which track themselves in
-- `supabase_migrations.schema_migrations`, not Ecto's `public` one).
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version    bigint      PRIMARY KEY,
  inserted_at timestamp without time zone
);

-- Mark the Supabase-backed baseline as already applied. Ecto will skip these
-- and only run the cutover migrations (Oban + pg_cron removal).
INSERT INTO public.schema_migrations (version, inserted_at)
VALUES
  (20260512000002, NOW()),
  (20260512000003, NOW()),
  (20260512000004, NOW()),
  (20260512000005, NOW()),
  (20260512000006, NOW()),
  (20260512000007, NOW()),
  (20260512000008, NOW()),
  (20260512000009, NOW()),
  (20260512000010, NOW()),
  (20260512000011, NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;