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
    test "the citext cast rejects collisions permitted by the previous text type" do
      Repo.query!("ALTER TABLE waitlist ALTER COLUMN email TYPE text USING email::text")

      email = unique_email("collision")
      insert_waitlist(email)
      insert_waitlist(String.upcase(email))

      assert_raise Postgrex.Error, fn ->
        Repo.query!("ALTER TABLE waitlist ALTER COLUMN email TYPE citext USING email::citext")
      end
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
end
