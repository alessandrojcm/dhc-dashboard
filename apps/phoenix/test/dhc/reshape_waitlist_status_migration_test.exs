defmodule Dhc.ReshapeWaitlistStatusMigrationTest do
  use Dhc.DataCase, async: false

  @migration Dhc.Repo.Migrations.ReshapeWaitlistStatus
  @version 20_261_009_120_000
  @schema "waitlist_status_migration_test"

  setup_all do
    Code.require_file("priv/repo/migrations/#{@version}_reshape_waitlist_status.exs")
    :ok
  end

  setup do
    Repo.query!("CREATE SCHEMA #{@schema}")
    Repo.query!("SET LOCAL search_path TO #{@schema}")

    Repo.query!("""
    CREATE TYPE waitlist_status AS ENUM
      ('waiting', 'invited', 'paid', 'deferred', 'cancelled', 'completed', 'no_reply', 'joined')
    """)

    Repo.query!("""
    CREATE TABLE waitlist (id uuid PRIMARY KEY, status waitlist_status NOT NULL DEFAULT 'waiting')
    """)

    Repo.query!("INSERT INTO waitlist (id) VALUES ('00000000-0000-0000-0000-000000000001')")
    :ok
  end

  test "swaps the enum on a fresh Ecto database and can roll back" do
    migrate(:up)
    assert_standings()
    migrate(:down)
    assert Repo.query!("SELECT status::text FROM waitlist").rows == [["waiting"]]
  end

  test "removes the inherited Supabase function before replacing its argument enum" do
    Repo.query!("""
    CREATE FUNCTION update_waitlist_status(uuid, waitlist_status, text)
    RETURNS void LANGUAGE sql AS 'SELECT NULL::void'
    """)

    migrate(:up)
    assert_standings()

    assert Repo.query!("""
           SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = '#{@schema}' AND p.proname = 'update_waitlist_status'
           """).rows == [[0]]
  end

  defp migrate(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      @migration,
      :forward,
      direction,
      direction,
      prefix: @schema,
      log: false
    )
  end

  defp assert_standings do
    assert Repo.query!("SELECT status::text, removed_at FROM waitlist").rows == [["waiting", nil]]

    assert Repo.query!("SELECT unnest(enum_range(NULL::waitlist_status))::text").rows ==
             Enum.map(~w(waiting removed attended invited joined), &[&1])
  end
end
