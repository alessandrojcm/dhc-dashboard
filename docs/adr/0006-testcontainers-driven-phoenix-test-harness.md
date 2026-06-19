# Testcontainers-driven Phoenix test harness

Status: accepted

The Phoenix Elixir test suite depended on a long-running, developer-managed `supabase start` instance (Postgres on `localhost:54322`), with `config/test.exs` hardcoding the port. We replace this with a testcontainers-elixir-driven Docker Compose stack that starts per `mix test` run and tears down on exit, removing the manual prerequisite.

The harness uses `Testcontainers.DockerCompose` (v2.3.1) to drive a stripped Supabase `docker-compose.yml` at the repo root, using `with_profile("db")` + `with_services(["db"])` to start only the Postgres service. The compose file is uniform-profile (every service carries a `profiles:` entry — `db` for Postgres, `supabase` for GoTrue/Kong/PostgREST) so E2E can later use the same file with `--profile supabase`. The `.env` at the repo root supplies Compose variable interpolation naturally (testcontainers-elixir sets `cd` to the compose file's directory, so a root-level file finds `.env` there).

The `db` service uses `supabase/postgres:17.6.1.136` — the upstream image — because Ecto migrations require `pg_jsonschema` (in the `extensions` schema) and FKs against `auth.users`. The image already ships `00000000000001-auth-schema.sql` at container init, creating the full `auth.users` table, `auth.schema_migrations`, and the `supabase_auth_admin` role. **No bespoke auth schema bootstrap SQL is written.** This was a real decision: we considered a hand-rolled minimal `auth.users(id, aud, role, email)` init script, but the image's built-in bootstrap is strictly better (zero drift from real GoTrue, no file to maintain) and free.

Because `mix test` auto-starts the application before `test_helper.exs` runs, `Application.put_env` for the dynamic port would arrive too late (Repo already started with the old config). We resolve this with a `test: ["test --no-start"]` Mix alias, and `test_helper.exs` takes ownership of startup: start `:hackney` (testcontainers-elixir's Tesla adapter needs it but doesn't list it in extra_applications, so `--no-start` leaves it down) → start compose → read dynamic port via `ComposeEnvironment.get_service_port/3` → `Application.put_env` (merging into the static config kept in `config/test.exs`) → start `:ecto_sql`/`:postgrex` and run migrations under a throwaway Repo supervisor (migrations run BEFORE the app, not after — Oban 2.23's `testing: :manual` still runs `verify_migrated!` at startup, so `oban_jobs` must exist before `Application.ensure_all_started(:dhc)`) → stop the throwaway supervisor → `Application.ensure_all_started(:dhc)` + `Application.ensure_all_started(:bypass)` (the latter because `--no-start` disables auto-start of test-only deps too, and Bypass needs its supervision tree up before `Bypass.open()`) → sandbox mode → `ExUnit.start()`. `System.at_exit` stops the app then the compose environment with `down -v` (the app stop is needed so Oban's Postgres notifier closes cleanly before the DB dies).

The lifecycle is per-run: full compose `up` at start, `down -v` on exit. No cross-run reuse — every run starts from a freshly migrated DB. Reuse (testcontainers-elixir's `with_reuse` applies to single containers, not compose; "leave project up" semantics would need separate plumbing) is deferred as an optimization. Cost is ~2-4s cold start per `mix test`, which is strictly better than the status quo (manual `supabase start` before any test run).

## Considered Options

- **Run GoTrue in the test profile too.** Rejected: the Phoenix harness stubs auth at the `:auth_verifier` seam — no test hits GoTrue/Kong/PostgREST. Running GoTrue adds a container and boot time for nothing.
- **Hand-rolled minimal `auth.users` init SQL.** Rejected: `supabase/postgres:17.6.1.136` already ships the full `auth.users` schema at init. A bespoke bootstrap would drift from real GoTrue and add a file to maintain.
- **Pre-baked migrated image.** Rejected: migrations are the source of truth and small (13 migrations); a second artifact to keep in sync isn't worth the cold-start savings.
- **Compose reuse across runs.** Deferred: reuse semantics for the compose module aren't equivalent to single-container `with_reuse`. Per-run `down -v` keeps the harness deterministic; reuse can be layered on later via a `--keep-db` env flag.
- **Subprocess `docker compose` (no testcontainers-elixir).** Rejected: loses the in-process `ComposeEnvironment` handle for dynamic port lookup, and the user explicitly asked for testcontainers-elixir.

## Consequences

- `mix test` is no longer the direct entry point — the `test` Mix alias wraps it with `--no-start`, and `test_helper.exs` owns the app startup. Running `mix test path/to/file.exs` still works through the alias.
- `config/test.exs` keeps static Repo config (username, password, database, pool); `test_helper.exs` owns the dynamic hostname/port.
- Docker must be available on the dev/CI machine running `mix test`.
- The compose file is structured to support E2E later (uniform profiles), but E2E's fixed-port and cookie-derivation concerns are out of scope and deferred.
- A new `mise run phx-test` task wraps `mix test` for consistency with the `phx-*` task naming. Dev workflow (`mix phx.server` against local Supabase) is unchanged.