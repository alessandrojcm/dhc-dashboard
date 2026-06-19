defmodule Dhc.Auth.AuthUserTest do
  @moduledoc """
  Repo-level test for the `Dhc.Auth.AuthUser` read-only schema.

  Verifies the schema reads `id` and `email` from `auth.users`, isolating the
  single `auth.users` read touchpoint at the schema boundary. Uses the shared
  `Dhc.MemberFixtures` helper to seed an auth user row (the fixture inserts
  into `auth.users` with `prefix: "auth"`).
  """

  use Dhc.DataCase, async: false

  import Ecto.Query

  alias Dhc.Auth.AuthUser
  alias Dhc.MemberFixtures
  alias Dhc.Repo

  # `:binary_id` fields load as 16-byte binaries; normalize to the string UUID
  # form so assertions read against the fixture's string ids.
  defp uuid_to_string(<<_::128>> = value) do
    {:ok, string} = Ecto.UUID.load(value)
    string
  end

  defp uuid_to_string(value), do: value

  describe "schema boundary read" do
    test "loads an auth.users row with id and email" do
      %{auth_user_id: auth_user_id_str} = MemberFixtures.member_fixture()

      %AuthUser{} = user = Repo.get(AuthUser, auth_user_id_str)

      # `id` is the binary UUID; the fixture generated the string form.
      assert uuid_to_string(user.id) == auth_user_id_str
      # The fixture mints a unique member-<n>@example.com address.
      assert is_binary(user.email)
      assert String.ends_with?(user.email, "@example.com")
    end

    test "returns nil when the auth user does not exist" do
      missing_id = Ecto.UUID.generate()

      assert Repo.get(AuthUser, missing_id) == nil
    end

    test "selects only id and email through an Ecto query" do
      %{auth_user_id: auth_user_id_str} = MemberFixtures.member_fixture()

      rows =
        from(u in AuthUser,
          where: u.id == ^auth_user_id_str,
          select: %{id: u.id, email: u.email}
        )
        |> Repo.all()

      assert [%{id: id, email: email}] = rows
      assert uuid_to_string(id) == auth_user_id_str
      assert is_binary(email)
    end
  end
end
