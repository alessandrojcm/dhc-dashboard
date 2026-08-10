defmodule Dhc.Ale184CitextTest do
  use Dhc.DataCase, async: false

  alias Dhc.Repo

  describe "email column types" do
    test "waitlist and external_users use citext" do
      assert column_type("waitlist", "email") == "citext"
      assert column_type("external_users", "email") == "citext"
    end
  end

  describe "case-variant collision characterization" do
    test "the migration gate reports collisions permitted by the previous text type" do
      Repo.query!("ALTER TABLE waitlist ALTER COLUMN email TYPE text USING email::text")

      email = unique_email("collision")
      insert_waitlist(email)
      insert_waitlist(String.upcase(email))

      error = assert_raise Postgrex.Error, &run_collision_gate!/0

      assert Map.get(error.postgres, :code) == :unique_violation
      assert Map.get(error.postgres, :message) =~ "waitlist groups: 1"
    end
  end

  describe "case-insensitive email uniqueness" do
    test "waitlist rejects a case variant of an existing email" do
      email = unique_email("waitlist")
      insert_waitlist(email)

      assert_raise Postgrex.Error, fn ->
        insert_waitlist(String.upcase(email))
      end
    end

    test "external_users rejects a case variant of an existing email" do
      email = unique_email("external")
      insert_external_user(email)

      assert_raise Postgrex.Error, fn ->
        insert_external_user(String.upcase(email))
      end
    end
  end

  defp column_type(table, column) do
    %{rows: [[type]]} =
      Repo.query!(
        """
        SELECT udt_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    type
  end

  defp insert_waitlist(email) do
    Repo.query!(
      """
      INSERT INTO waitlist (email, status, initial_registration_date, last_status_change)
      VALUES ($1, 'waiting', NOW(), NOW())
      """,
      [email]
    )
  end

  defp insert_external_user(email) do
    Repo.query!(
      """
      INSERT INTO external_users (first_name, last_name, email, created_at, updated_at)
      VALUES ('External', 'Guest', $1, NOW(), NOW())
      """,
      [email]
    )
  end

  defp unique_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end

  defp run_collision_gate! do
    Repo.query!("""
    DO $$
    DECLARE waitlist_collisions bigint;
    DECLARE external_user_collisions bigint;
    BEGIN
      SELECT count(*) INTO waitlist_collisions
        FROM (
          SELECT lower(email) FROM waitlist GROUP BY lower(email) HAVING count(*) > 1
        ) duplicates;

      SELECT count(*) INTO external_user_collisions
        FROM (
          SELECT lower(email) FROM external_users GROUP BY lower(email) HAVING count(*) > 1
        ) duplicates;

      IF waitlist_collisions > 0 OR external_user_collisions > 0 THEN
        RAISE EXCEPTION
          'ALE-184: case-insensitive email collisions found (waitlist groups: %, external_users groups: %)',
          waitlist_collisions, external_user_collisions
          USING ERRCODE = 'unique_violation';
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """)
  end
end
