    -- -- /*---------------------
    -- -- ---- install dbdev ----
    -- -- ----------------------
    -- -- Requires:
    -- --   - pg_tle: https://github.com/aws/pg_tle
    -- --   - pgsql-http: https://github.com/pramsey/pgsql-http
    -- -- */
    -- create extension if not exists http with schema extensions;
    -- create extension if not exists pg_tle;
    -- drop extension if exists "supabase-dbdev";
    -- select pgtle.uninstall_extension_if_exists('supabase-dbdev');
    -- select pgtle.install_extension(
    --                'supabase-dbdev',
    --                resp.contents ->> 'version',
    --                'PostgreSQL package manager',
    --                resp.contents ->> 'sql'
    --        )
    -- from http(
    --              (
    --               'GET',
    --               'https://api.database.dev/rest/v1/'
    --                   || 'package_versions?select=sql,version'
    --                   || '&package_name=eq.supabase-dbdev'
    --                   || '&order=version.desc'
    --                   || '&limit=1',
    --               array [
    --                   ('apiKey',
    --                    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhtdXB0cHBsZnZpaWZyYndtbXR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE2ODAxMDczNzIsImV4cCI6MTk5NTY4MzM3Mn0.z2CN0mvO2No8wSi46Gw59DFGCTJrzM0AQKsu_5k134s')::http_header
    --                   ],
    --               null,
    --               null
    --                  )
    --      ) x,
    --      lateral (
    --          select ((row_to_json(x) -> 'content') #>> '{}')::json -> 0
    --          ) resp(contents);
    -- create extension if not exists "supabase-dbdev";
    -- select dbdev.install('supabase-dbdev');
    -- select dbdev.install('basejump-supabase_test_helpers');

    -- ── Ecto migration bridge ────────────────────────────────────────
    -- After `supabase db reset`, the schema is created by the (frozen)
    -- Supabase SQL migrations in `supabase/migrations/`. Ecto's
    -- `public.schema_migrations` bookkeeping table is empty at this point, so
    -- `mix ecto.migrate` would try to recreate the baseline enums/tables and
    -- fail on duplicates. This block marks the Supabase-backed baseline
    -- versions as already applied so Ecto skips them and only runs the
    -- cutover migrations (Oban + pg_cron removal).
    --
    -- Mirrors `scripts/bridge.sql`; kept here so a single `supabase:reset`
    -- leaves the DB ready for Phoenix. Idempotent via ON CONFLICT.
    -- See AGENTS.md → "MIGRATION NOTES".

    DO $$
    BEGIN
      CREATE TABLE IF NOT EXISTS public.schema_migrations (
        version    bigint      PRIMARY KEY,
        inserted_at timestamp without time zone
      );

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
    END
    $$;