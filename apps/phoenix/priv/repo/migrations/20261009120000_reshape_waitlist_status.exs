defmodule Dhc.Repo.Migrations.ReshapeWaitlistStatus do
  @moduledoc """
  ALE-375: Waitlist Status becomes a person's standing in the queue rather
  than their progress through one workshop:
  `waiting | removed | attended | invited | joined`.

  The legacy one-workshop values (`paid deferred cancelled completed
  no_reply`) are dropped with no mapping because there is no production
  Waitlist data. `removed_at` records when the current `removed` standing
  started (the 3-month retention clock); a CHECK keeps it set exactly while
  the status is `removed`.

  ## Deploy shape

  Non-splittable enum swap (`ALTER COLUMN ... TYPE` rewrites the `waitlist`
  table under an ACCESS EXCLUSIVE lock). It runs routinely at release time
  only because the production `waitlist` table holds no rows with a legacy
  status. Operator pre-flight gate (must return 0):

      SELECT count(*) FROM waitlist
      WHERE status::text IN ('paid', 'deferred', 'cancelled', 'completed', 'no_reply');

  The migration repeats the gate and aborts before changing the schema if
  it fails. A local dev database seeded before this change fails the gate:
  reset it (`mix ecto.reset`) and re-seed.
  """

  use Ecto.Migration

  @check :waitlist_removed_at_matches_status

  def up do
    execute """
    DO $$
    DECLARE legacy_rows bigint;
    BEGIN
      SELECT count(*) INTO legacy_rows FROM waitlist
      WHERE status::text IN ('paid', 'deferred', 'cancelled', 'completed', 'no_reply');

      IF legacy_rows > 0 THEN
        RAISE EXCEPTION 'ALE-375 data gate failed: % waitlist rows carry a legacy status', legacy_rows;
      END IF;
    END
    $$;
    """

    swap_status_type(~w(waiting removed attended invited joined))

    alter table(:waitlist) do
      add :removed_at, :timestamptz
    end

    create constraint(:waitlist, @check, check: "(status = 'removed') = (removed_at IS NOT NULL)")
  end

  def down do
    execute """
    DO $$
    DECLARE new_rows bigint;
    BEGIN
      SELECT count(*) INTO new_rows FROM waitlist WHERE status::text IN ('removed', 'attended');

      IF new_rows > 0 THEN
        RAISE EXCEPTION 'ALE-375 rollback gate failed: % waitlist rows are removed or attended', new_rows;
      END IF;
    END
    $$;
    """

    drop constraint(:waitlist, @check)

    alter table(:waitlist) do
      remove :removed_at
    end

    swap_status_type(~w(waiting invited paid deferred cancelled completed no_reply joined))
  end

  defp swap_status_type(values) do
    labels = Enum.map_join(values, ", ", &"'#{&1}'")

    execute "CREATE TYPE waitlist_status_next AS ENUM (#{labels})"
    execute "ALTER TABLE waitlist ALTER COLUMN status DROP DEFAULT"

    execute """
    ALTER TABLE waitlist
      ALTER COLUMN status TYPE waitlist_status_next USING status::text::waitlist_status_next
    """

    execute "ALTER TABLE waitlist ALTER COLUMN status SET DEFAULT 'waiting'"
    execute "DROP TYPE waitlist_status"
    execute "ALTER TYPE waitlist_status_next RENAME TO waitlist_status"
  end
end
