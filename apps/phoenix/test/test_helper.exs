# test_helper.exs — owns the full test DB lifecycle (ADR 0006).
#
# Order matters (ADR 0006 line 11 is authoritative). The `test` Mix alias wraps
# `mix test` with `--no-start`, so Mix does NOT auto-start :dhc or :bypass before
# this file runs. That lets us:
#
#   1. Start the testcontainers GenServer.
#   2. Build the Docker Compose config (root docker-compose.yml, `db` profile,
#      `db` service only).
#   3. Start compose — `docker compose --profile db up -d --wait` runs and gates
#      on the `pg_isready` healthcheck in docker-compose.yml.
#   4. Read the dynamically-allocated host port for the db service's internal
#      5432. testcontainers allocates a random host port per run; this is the
#      whole point of the harness (no fixed port, no leftover state).
#   5. Merge the dynamic hostname/port into the static Repo config kept in
#      config/test.exs (username/password/database/pool). put_env REPLACES,
#      so we Keyword.merge/2 to keep the static keys.
#   6. Run migrations BEFORE starting the full app. Oban (a child of the app
#      supervisor) verifies the `oban_jobs` table exists at startup unless
#      `testing: :disabled` — but `:manual` is the correct test mode for us
#      (it disables peers/plugins/queues for isolation while still allowing
#      manual job insertion), and `:manual` still runs `verify_migrated!`. So
#      migrations must land before `Application.ensure_all_started(:dhc)`.
#      Ecto.Migrator needs the Repo started, but starting the full app also
#      starts Oban (chicken-and-egg). Resolution: start the Repo alone under a
#      throwaway supervisor, run migrations, stop it, then start the app — the
#      app's own supervisor re-starts the Repo cleanly.
#   7. Start :dhc (Oban's verify_migrated! now passes) and :bypass (test-only
#      dep; --no-start disabled its autostart too, and Bypass.open() needs its
#      supervision tree up).
#   8. Sandbox mode + ExUnit.
#   9. Tear down on exit — `docker compose down -v` removes volumes
#      (testcontainers-elixir's DockerCompose defaults remove_volumes: true,
#      so down -v runs automatically; no with_remove_volumes(true) needed).

# 1. Start the testcontainers GenServer (linked to this helper process, which
#    owns the whole test run, so it dies with the VM — its terminate/2 callback
#    also runs ComposeCli.down for tracked envs as a safety net).
#
#    testcontainers-elixir talks to the Docker daemon via Tesla+Hackney, but
#    Hackney is NOT in testcontainers' extra_applications — so even an
#    Application.ensure_all_started(:testcontainers) won't bring it up. With
#    --no-start disabling the normal dep-tree autostart, we must start
#    :hackney ourselves before any Testcontainers call, or Hackney's metrics
#    ETS table is missing and the first HTTP call crashes.
Application.ensure_all_started(:hackney)
{:ok, _} = Testcontainers.start_link()

# 2. Build the compose config — root docker-compose.yml, db profile only.
compose_config =
  Testcontainers.DockerCompose.new(".")
  |> Testcontainers.DockerCompose.with_profile("db")
  |> Testcontainers.DockerCompose.with_services(["db"])

# 3. Start compose (runs `docker compose --profile db up -d --wait`; gates on
#    the upstream pg_isready healthcheck — no explicit wait strategy needed).
{:ok, env} = Testcontainers.start_compose(compose_config)

# 4. Read the dynamically-allocated host port for the db service. The third
#    argument MUST be an integer (the container-internal port 5432); the
#    guard is is_integer(port). Returns nil if the service isn't found.
port = Testcontainers.Compose.ComposeEnvironment.get_service_port(env, "db", 5432)

if is_nil(port) do
  raise """
  db service did not expose port 5432 to the host.
  Check docker-compose.yml (db must be in the `db` profile and expose "5432")
  and that `docker compose --profile db up -d --wait` reports the db container
  healthy.
  """
end

# 5. Merge the dynamic hostname/port into the static Repo config. The static
#    config (username, password, database, pool, pool_size) stays in
#    config/test.exs; only hostname/port are dynamic per run.
repo_config = Application.get_env(:dhc, Dhc.Repo, [])
Application.put_env(:dhc, Dhc.Repo, Keyword.merge(repo_config, hostname: "localhost", port: port))

# 6. Run migrations BEFORE starting the full app. Oban (a child of the app
#    supervisor) runs `verify_migrated!` at startup when `testing: :manual`
#    (our mode — disables peers/plugins/queues but still checks the table),
#    so `oban_jobs` must exist before `Application.ensure_all_started(:dhc)`.
#    Ecto.Migrator needs the Repo started; starting the Repo alone under a
#    throwaway supervisor avoids dragging Oban up first. We stop this supervisor
#    before starting the app so the app's own supervisor owns the Repo cleanly.
#
#    The Repo's DBConnection pool depends on the :ecto_sql / :postgrex /
#    :db_connection applications being started — with `--no-start` nothing is
#    up yet, so start the core DB stack explicitly before the migration Repo.
#    `pool: Ecto.Adapters.SQL.Sandbox` from config/test.exs is wrong for
#    migrations (the sandbox pool needs an owning process checked out via
#    `sandbox_mode/2`); override to a regular pool for the migration run only.
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)

migration_config =
  repo_config
  |> Keyword.merge(hostname: "localhost", port: port)
  |> Keyword.delete(:pool)

{:ok, migration_sup} =
  Supervisor.start_link(
    [{Dhc.Repo, migration_config}],
    strategy: :one_for_one,
    name: Dhc.TestMigrationSupervisor
  )

Ecto.Migrator.run(Dhc.Repo, "priv/repo/migrations", :up, all: true)
:ok = Supervisor.stop(migration_sup)

# 7. Start the app (Oban's verify_migrated! now passes) + Bypass.
#    --no-start disabled both, so test_helper.exs owns startup ordering.
Application.ensure_all_started(:dhc)
Application.ensure_all_started(:bypass)

# 8. Sandbox + ExUnit.
Ecto.Adapters.SQL.Sandbox.mode(Dhc.Repo, :manual)
ExUnit.configure(exclude: [integration: true])
ExUnit.start()

# 9. Tear down on exit. Stop the app FIRST so Oban's Postgres notifier and
#    other DB-connected processes close their connections cleanly; otherwise
#    they try to reconnect mid-shutdown and log scary-but-benign errors
#    ("the database system is shutting down"). Then stop_compose/1 runs
#    `docker compose down -v` (the DockerCompose struct defaults
#    remove_volumes: true — no need to opt in). Fresh container + fresh data
#    next run.
#
#    The stop_compose/1 call is wrapped in a catch because it GenServer.calls the
#    Testcontainers GenServer, which is linked to this helper process and may
#    already be terminating during VM shutdown — a {:EXIT, :normal} there is
#    harmless (compose's terminate/2 callback also runs `down -v` as a safety
#    net). We don't want a benign race to mask real test failures in the exit
#    code.
System.at_exit(fn _ ->
  Application.stop(:dhc)

  try do
    Testcontainers.stop_compose(env)
  catch
    :exit, {:normal, _} -> :ok
    :exit, _ -> :ok
  end
end)
