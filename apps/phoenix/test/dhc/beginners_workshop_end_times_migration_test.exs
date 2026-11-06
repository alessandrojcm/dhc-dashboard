defmodule Dhc.BeginnersWorkshopEndTimesMigrationTest do
  use Dhc.DataCase, async: false

  @migration Dhc.Repo.Migrations.BackfillBeginnersWorkshopEndTimes
  @version 20_261_106_084_732
  @schema "beginners_end_times_migration_test"

  setup_all do
    Code.require_file(
      "priv/repo/migrations/#{@version}_backfill_beginners_workshop_end_times.exs"
    )

    :ok
  end

  setup do
    Repo.query!("CREATE SCHEMA #{@schema}")
    Repo.query!("SET LOCAL search_path TO #{@schema}")

    Repo.query!("""
    CREATE TABLE beginners_workshops (
      id integer PRIMARY KEY, date date NOT NULL, start_time time NOT NULL,
      end_time time, payment_cutoff timestamptz NOT NULL,
      contact_from date NOT NULL, reschedule_count integer NOT NULL DEFAULT 0
    )
    """)

    Repo.query!("""
    INSERT INTO beginners_workshops
      (id, date, start_time, end_time, payment_cutoff, contact_from)
    VALUES
      (1, '2027-03-28', '10:00', NULL, '2027-03-25 10:00Z', '2027-03-01'),
      (2, '2026-10-25', '11:30', NULL, '2026-10-22 10:30Z', '2026-10-01'),
      (3, '2026-11-14', '10:00', '15:00', '2026-11-11 10:00Z', '2026-11-01'),
      (4, '2026-11-14', '18:00', NULL, '2026-11-11 18:00Z', '2026-11-01'),
      (5, '2026-11-14', '23:00', NULL, '2026-11-11 23:00Z', '2026-11-01'),
      (6, '2026-11-14', '17:59:59', NULL, '2026-11-11 17:59:59Z', '2026-11-01')
    """)

    :ok
  end

  test "fills only unknown same-day ends with the approved six civil hours, preserving schedule policy" do
    before = policy_rows()
    migrate(:up)

    assert Repo.query!("SELECT id, end_time FROM beginners_workshops ORDER BY id").rows == [
             [1, ~T[16:00:00.000000]],
             [2, ~T[17:30:00.000000]],
             [3, ~T[15:00:00.000000]],
             [4, nil],
             [5, nil],
             [6, ~T[23:59:59.000000]]
           ]

    assert policy_rows() == before
    migrate(:up)
    assert policy_rows() == before

    # Rolling the release back must not erase either baseline data or a
    # coordinator's subsequent correction, which cannot be distinguished.
    Repo.query!("UPDATE beginners_workshops SET end_time = '16:30' WHERE id = 1")
    migrate(:down)

    assert Repo.query!("SELECT end_time FROM beginners_workshops WHERE id = 1").rows == [
             [~T[16:30:00.000000]]
           ]
  end

  defp policy_rows do
    Repo.query!("""
    SELECT id, date, start_time, payment_cutoff, contact_from, reschedule_count
    FROM beginners_workshops ORDER BY id
    """).rows
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
end
