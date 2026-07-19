defmodule Dhc.AuthTest do
  use Dhc.DataCase, async: true

  alias Dhc.Auth
  alias Dhc.Auth.Principal
  alias Dhc.Auth.PrincipalToken
  alias Dhc.Repo

  import Dhc.AuthFixtures

  describe "get_principal_by_email/1" do
    test "returns nil for an unknown email" do
      refute Auth.get_principal_by_email("nobody@example.com")
    end

    test "returns the Principal for a matching email" do
      principal = principal_fixture()
      found = Auth.get_principal_by_email(principal.email)
      assert %Principal{} = found
      assert found.id == principal.id
    end

    test "normalizes email before lookup (case-insensitive, trimmed)" do
      principal = principal_fixture(email: "member@example.com")
      found = Auth.get_principal_by_email("  MEMBER@EXAMPLE.COM  ")
      assert %Principal{} = found
      assert found.id == principal.id
    end
  end

  describe "register_principal/1" do
    test "normalizes email on insert" do
      {:ok, principal} = Auth.register_principal(%{email: "  Mixed.Case@Example.com  "})
      assert principal.email == "mixed.case@example.com"
    end

    test "rejects a duplicate normalized email (citext)" do
      principal_fixture(email: "dup@example.com")
      {:error, changeset} = Auth.register_principal(%{email: "DUP@example.com"})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "rejects malformed email" do
      {:error, changeset} = Auth.register_principal(%{email: "no-at-sign"})
      assert "must have the @ sign and no spaces" in errors_on(changeset).email
    end
  end

  describe "deliver_magic_link/2" do
    test "returns {:ok, :sent} for an unknown email (non-enumerating)" do
      initial_oban_count = oban_jobs_count()

      assert {:ok, :sent} =
               Auth.deliver_magic_link("nobody@example.com", &"#{&1}")

      # No token row, no email job enqueued.
      assert Repo.aggregate(PrincipalToken, :count) == 0
      assert oban_jobs_count() == initial_oban_count
    end

    test "writes a magic-link token and enqueues an email for a known Principal" do
      principal = principal_fixture()
      initial_oban_count = oban_jobs_count()

      assert {:ok, :sent} =
               Auth.deliver_magic_link(principal.email, fn token ->
                 "https://app.example.com/auth/magic-link?token=#{token}"
               end)

      # One login token row, one email job.
      assert Repo.aggregate(
               from(t in PrincipalToken, where: t.context == "login"),
               :count
             ) == 1

      assert oban_jobs_count() == initial_oban_count + 1
    end

    test "does not disclose Principal existence by side-channel timing of side effects" do
      # Second call to a known Principal still returns the same tuple shape
      # as an unknown one. (This is a shape assertion, not a timing test.)
      principal = principal_fixture()

      assert {:ok, :sent} =
               Auth.deliver_magic_link(principal.email, &"#{&1}")

      assert {:ok, :sent} =
               Auth.deliver_magic_link("unknown@example.com", &"#{&1}")
    end
  end

  describe "consume_magic_link/1" do
    test "consumes a valid token, confirms the Principal, and mints a session" do
      principal = principal_fixture(confirmed_at: nil)
      {encoded, _row} = magic_link_token(principal)

      assert {:ok, %{principal: returned_principal, session_token: session_token}} =
               Auth.consume_magic_link(encoded)

      assert returned_principal.id == principal.id
      # confirmed_at was stamped on first consumption.
      assert Auth.get_principal!(principal.id).confirmed_at

      # The session token is verifiable.
      assert {:ok, _} = Auth.get_principal_by_session_token(session_token)
    end

    test "is single-use: the second attempt is invalid" do
      principal = principal_fixture()
      {encoded, _row} = magic_link_token(principal)

      assert {:ok, _} = Auth.consume_magic_link(encoded)
      assert {:error, :invalid} = Auth.consume_magic_link(encoded)
    end

    test "deletes outstanding magic-link tokens for the principal on consumption" do
      principal = principal_fixture()
      {_, _} = magic_link_token(principal)
      {_, _} = magic_link_token(principal)

      assert Repo.aggregate(
               from(t in PrincipalToken, where: [principal_id: ^principal.id, context: "login"]),
               :count
             ) == 2

      {encoded, _} = magic_link_token(principal)
      assert {:ok, _} = Auth.consume_magic_link(encoded)

      # All login tokens for this principal are gone (including the consumed
      # one and the two outstanding).
      assert Repo.aggregate(
               from(t in PrincipalToken, where: [principal_id: ^principal.id, context: "login"]),
               :count
             ) == 0
    end

    test "rejects an expired token (older than 15 minutes)" do
      principal = principal_fixture()
      {encoded, row} = magic_link_token(principal)
      # 16 minutes old — past the 15-min window.
      age_token(row.token, -16, :minute)

      assert {:error, :invalid} = Auth.consume_magic_link(encoded)
    end

    test "rejects a token sent to an email that no longer matches the Principal" do
      principal = principal_fixture(email: "old@example.com")
      {encoded, _row} = magic_link_token(principal)

      # Change the principal's email after the link was issued.
      {:ok, _} =
        principal
        |> Principal.email_changeset(%{email: "new@example.com"})
        |> Repo.update()

      assert {:error, :invalid} = Auth.consume_magic_link(encoded)
    end

    test "rejects garbage input without raising" do
      assert {:error, :invalid} = Auth.consume_magic_link("not-a-real-token")
    end

    test "rejects a token for an unknown principal (no row)" do
      assert {:error, :invalid} =
               Auth.consume_magic_link("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    end
  end

  describe "sessions" do
    test "create_session/1 inserts a verifiable session token" do
      principal = principal_fixture()
      {:ok, token} = Auth.create_session(principal)

      assert {:ok, returned} = Auth.get_principal_by_session_token(token)
      assert returned.id == principal.id
    end

    test "get_principal_by_session_token/1 rejects an unknown token" do
      assert {:error, :invalid} =
               Auth.get_principal_by_session_token(:crypto.strong_rand_bytes(32))
    end

    test "get_principal_by_session_token/1 rejects an expired session (>30 days)" do
      principal = principal_fixture()
      {:ok, token} = Auth.create_session(principal)

      # Age the session row past 30 days.
      age_token(token, -31, :day)

      assert {:error, :invalid} = Auth.get_principal_by_session_token(token)
    end

    test "delete_session_token/1 is idempotent" do
      principal = principal_fixture()
      {:ok, token} = Auth.create_session(principal)

      assert :ok = Auth.delete_session_token(token)
      assert :ok = Auth.delete_session_token(token)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(token)
    end

    test "delete_all_principal_sessions/1 removes every session for the principal" do
      principal = principal_fixture()
      {:ok, t1} = Auth.create_session(principal)
      {:ok, t2} = Auth.create_session(principal)

      assert :ok = Auth.delete_all_principal_sessions(principal)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(t1)
      assert {:error, :invalid} = Auth.get_principal_by_session_token(t2)
    end
  end

  describe "load_session_principal/1" do
    test "returns roles and is_active when the Principal has a user_profile and roles" do
      # Build the Supabase/auth.users + user_profiles + member_profiles shape
      # with Dhc.MemberFixtures, then a Principal sharing the same UUID as
      # auth.users.id (the post-M1 invariant).
      auth_user_id = Ecto.UUID.generate()

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: "active@example.com"
      })

      # Grant the member a role.
      Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(auth_user_id), role: "member"]])

      principal = principal_fixture(id: auth_user_id, email: "active@example.com")

      assert {:ok, projection} = Auth.load_session_principal(principal)
      assert projection.principal.id == principal.id
      assert projection.is_active == true
      assert "member" in projection.roles
    end

    test "returns is_active=false when the user_profile is inactive" do
      auth_user_id = Ecto.UUID.generate()

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: false
      })

      principal = principal_fixture(id: auth_user_id)

      assert {:ok, projection} = Auth.load_session_principal(principal)
      assert projection.is_active == false
    end

    test "returns no_profile when the Principal has no user_profile" do
      principal = principal_fixture()
      assert {:error, :no_profile} = Auth.load_session_principal(principal)
    end
  end

  # Helpers

  defp oban_jobs_count do
    Repo.aggregate("oban_jobs", :count)
  end
end
