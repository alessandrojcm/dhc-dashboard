defmodule Dhc.MemberProfiles.MemberProfileTest do
  @moduledoc """
  Repo-level test for the `Dhc.MemberProfiles.MemberProfile` schema.

  Verifies the schema reads `member_profiles` rows with the full expected
  column set, at the schema boundary — independent of any HTTP endpoint.
  Uses the shared `Dhc.MemberFixtures` helper to seed the auth user, user
  profile, and member profile rows the schema joins against.
  """

  use Dhc.DataCase, async: false

  import Ecto.Query

  alias Dhc.MemberProfiles.MemberProfile
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
    test "loads a member_profiles row with every mapped field populated" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %{auth_user_id: auth_user_id_str, profile_id: profile_id_str} =
        MemberFixtures.member_fixture(
          last_payment_date: now,
          preferred_weapon: ["longsword", "sword_and_buckler"]
        )

      %MemberProfile{} = profile = Repo.get(MemberProfile, auth_user_id_str)

      assert uuid_to_string(profile.id) == auth_user_id_str
      assert uuid_to_string(profile.user_profile_id) == profile_id_str
      assert profile.next_of_kin_name == "Next of Kin"
      assert profile.next_of_kin_phone == "+353820000000"

      # Postgrex decodes the `preferred_weapon` enum array as strings.
      assert profile.preferred_weapon == ["longsword", "sword_and_buckler"]

      assert %DateTime{} = profile.membership_start_date
      assert profile.membership_end_date == nil
      assert profile.last_payment_date == now
      assert profile.insurance_form_submitted == false
      assert profile.additional_data == %{}
      assert profile.subscription_paused_until == nil

      # Timestamps are mapped via the `inserted_at: :created_at` rename.
      assert %DateTime{} = profile.created_at
      assert %DateTime{} = profile.updated_at
    end

    test "returns nil when the member profile does not exist" do
      missing_id = Ecto.UUID.generate()

      assert Repo.get(MemberProfile, missing_id) == nil
    end

    test "selects a subset of fields through an Ecto query" do
      %{profile_id: profile_id_str} = MemberFixtures.member_fixture()

      rows =
        from(m in MemberProfile,
          where: m.user_profile_id == ^profile_id_str,
          select: %{user_profile_id: m.user_profile_id, kin: m.next_of_kin_name}
        )
        |> Repo.all()

      assert [%{user_profile_id: user_profile_id, kin: "Next of Kin"}] = rows
      assert uuid_to_string(user_profile_id) == profile_id_str
    end
  end
end
