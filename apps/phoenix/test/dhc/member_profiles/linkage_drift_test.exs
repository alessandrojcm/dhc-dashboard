defmodule Dhc.MemberProfiles.LinkageDriftTest do
  @moduledoc """
  ALE-180: enforce the triangle invariant
  `member_profiles.id == user_profiles.principal_id` at the DB layer.

  The migration drops the non-unique `member_profiles.user_profile_id` index
  and adds a unique one, adds a partial `user_profiles(customer_id)` unique
  index, and creates `verify_linkage_drift()` plus three constraint triggers
  (INSERT on member_profiles, UPDATE on member_profiles.user_profile_id,
  UPDATE on user_profiles.principal_id). The triggers raise only when a
  linked pair exists and disagrees, so waitlist-only profiles (no
  MemberProfile yet) are untouched.

  Per the ALE-180 spec, four tests cover the behavior: characterization red,
  desired green, waitlist-conversion regression, and UPDATE paths.
  """

  use Dhc.DataCase, async: false

  alias Dhc.MemberFixtures
  alias Dhc.Repo

  # The constraint trigger raises with this condition name so we can match the
  # Postgrex error regardless of the function body's message wording.
  @linkage_drift_constraint "linkage_drift_violation"

  describe "characterization: linkage drift is rejected after ALE-180" do
    # This test pins the DESIRED behavior: after the migration, a
    # member_profiles row whose id (principal) disagrees with the linked
    # user_profiles.principal_id is rejected by the constraint trigger. Before
    # ALE-180 the drift was silently accepted. The test goes red against the
    # pre-migration schema (drift succeeds) and green after the migration.
    test "INSERT member_profiles with principal_id != user_profiles.principal_id raises" do
      # A UserProfile owned by one Principal.
      owner_principal_id = Ecto.UUID.generate()
      {:ok, _} = Dhc.Auth.register_principal_with_id(owner_principal_id, %{email: unique_email()})

      profile_id = Ecto.UUID.generate()

      _ =
        Repo.query!(
          """
          INSERT INTO user_profiles
            (id, principal_id, first_name, last_name, is_active, date_of_birth,
             gender, phone_number, social_media_consent, created_at, updated_at)
          VALUES ($1, $2, 'Drift', 'Member', true, '1990-01-01',
                  'man (cis)', '+353810000000', 'no', NOW(), NOW())
          """,
          [Ecto.UUID.dump!(profile_id), Ecto.UUID.dump!(owner_principal_id)]
        )

      # A DIFFERENT Principal that does not own the UserProfile above.
      drift_principal_id = Ecto.UUID.generate()
      {:ok, _} = Dhc.Auth.register_principal_with_id(drift_principal_id, %{email: unique_email()})

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            """
            INSERT INTO member_profiles
              (id, user_profile_id, next_of_kin_name, next_of_kin_phone,
               preferred_weapon, membership_start_date, insurance_form_submitted,
               additional_data, created_at, updated_at)
            VALUES ($1, $2, 'Kin', '+353820000000', ARRAY['longsword']::preferred_weapon[],
                    NOW(), false, '{}'::jsonb, NOW(), NOW())
            """,
            [Ecto.UUID.dump!(drift_principal_id), Ecto.UUID.dump!(profile_id)]
          )
        end

      assert_linkage_drift_violation(error)
    end
  end

  describe "desired: a linked pair that agrees is accepted" do
    test "INSERT member_profiles aligned with user_profiles.principal_id succeeds" do
      # The standard member_fixture creates a fully aligned triangle
      # (member_profiles.id == user_profiles.principal_id), so it should pass
      # the constraint trigger.
      %{principal_id: principal_id, profile_id: profile_id} = MemberFixtures.member_fixture()

      assert [[^principal_id]] =
               Repo.query!(
                 "SELECT id::text FROM member_profiles WHERE id = $1",
                 [Ecto.UUID.dump!(principal_id)]
               ).rows

      assert [[^profile_id]] =
               Repo.query!(
                 "SELECT user_profile_id::text FROM member_profiles WHERE id = $1",
                 [Ecto.UUID.dump!(principal_id)]
               ).rows
    end

    test "user_profiles(customer_id) partial unique rejects duplicate non-null customer ids" do
      customer_id = "cus_#{System.unique_integer([:positive])}"

      MemberFixtures.member_fixture(customer_id: customer_id)

      error =
        assert_raise(Ecto.ConstraintError, fn ->
          MemberFixtures.member_fixture(customer_id: customer_id)
        end)

      assert error.constraint == "user_profiles_customer_id_unique"
    end

    test "user_profiles(customer_id) partial unique allows multiple NULL customer ids" do
      # Two profiles with NULL customer_id must coexist (the unique index is
      # partial: WHERE customer_id IS NOT NULL).
      MemberFixtures.member_fixture(customer_id: nil)

      # Insert a second profile directly with NULL customer_id (the fixture
      # generates a customer_id by default, so use a raw insert here).
      principal_id = Ecto.UUID.generate()
      {:ok, _} = Dhc.Auth.register_principal_with_id(principal_id, %{email: unique_email()})

      _ =
        Repo.query!(
          """
          INSERT INTO user_profiles
            (id, principal_id, first_name, last_name, is_active, date_of_birth,
             gender, phone_number, social_media_consent, customer_id,
             created_at, updated_at)
          VALUES ($1, $2, 'Second', 'Profile', true, '1990-01-01',
                  'man (cis)', '+353810000000', 'no', NULL, NOW(), NOW())
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(principal_id)]
        )

      :ok
    end
  end

  describe "waitlist-conversion regression: waitlist-only profiles are untouched" do
    # A waitlist-only UserProfile has no MemberProfile yet. The constraint
    # trigger must NOT raise for these, because no linked pair exists to
    # disagree. ALE-176 made waitlist UserProfiles carry a `waitlist_id`; this
    # test confirms that creating/altering such a profile does not trip the
    # linkage drift trigger.
    test "a waitlist-only UserProfile with no MemberProfile inserts freely" do
      # A UserProfile linked to a waitlist entry but to NO principal yet
      # (principal_id NULL) — exactly the waitlist-intake shape.
      waitlist_id = seed_waitlist_entry()

      _ =
        Repo.query!(
          """
          INSERT INTO user_profiles
            (id, principal_id, waitlist_id, first_name, last_name, is_active,
             date_of_birth, gender, phone_number, social_media_consent,
             created_at, updated_at)
          VALUES ($1, NULL, $2, 'Waitlist', 'Intake', true, '1990-01-01',
                  'man (cis)', '+353810000000', 'no', NOW(), NOW())
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(waitlist_id)]
        )

      :ok
    end

    test "converting a waitlist UserProfile (setting principal_id) does not raise when no MemberProfile exists" do
      waitlist_id = seed_waitlist_entry()
      profile_id = Ecto.UUID.generate()

      _ =
        Repo.query!(
          """
          INSERT INTO user_profiles
            (id, principal_id, waitlist_id, first_name, last_name, is_active,
             date_of_birth, gender, phone_number, social_media_consent,
             created_at, updated_at)
          VALUES ($1, NULL, $2, 'Waitlist', 'Convert', true, '1990-01-01',
                  'man (cis)', '+353810000000', 'no', NOW(), NOW())
          """,
          [Ecto.UUID.dump!(profile_id), Ecto.UUID.dump!(waitlist_id)]
        )

      # Conversion: accept the invitation, which sets principal_id on the
      # existing waitlist UserProfile. No MemberProfile exists yet, so the
      # UPDATE trigger on user_profiles.principal_id must NOT raise.
      principal_id = Ecto.UUID.generate()
      {:ok, _} = Dhc.Auth.register_principal_with_id(principal_id, %{email: unique_email()})

      result =
        Repo.query!(
          "UPDATE user_profiles SET principal_id = $1, updated_at = NOW() WHERE id = $2",
          [Ecto.UUID.dump!(principal_id), Ecto.UUID.dump!(profile_id)]
        )

      assert result.num_rows == 1

      :ok
    end

    test "the unique member_profiles.user_profile_id index is in place (structural 1:1 guard)" do
      # The unique index on member_profiles.user_profile_id is the structural
      # backstop for the 1:1 UserProfile→MemberProfile relationship. With the
      # drift trigger also in place, a misaligned second insert is rejected by
      # the trigger before the index would see it; the index still exists as a
      # defense-in-depth guard. Assert it is present and unique.
      assert [[true, indexdef]] =
               Repo.query!(
                 """
                 SELECT
                   idxs.indexname = $1 AS exists,
                   idxs.indexdef
                 FROM pg_indexes idxs
                 WHERE idxs.indexname = $1
                 """,
                 ["member_profiles_user_profile_id_unique"]
               ).rows

      assert indexdef =~ "CREATE UNIQUE INDEX"
      assert indexdef =~ "member_profiles_user_profile_id_unique"
      assert indexdef =~ "user_profile_id"
    end
  end

  describe "UPDATE paths enforce the invariant on mutation" do
    test "UPDATE member_profiles.user_profile_id to a profile owned by a different Principal raises" do
      member_a = MemberFixtures.member_fixture()

      # A standalone UserProfile owned by a DIFFERENT Principal, with no
      # MemberProfile of its own (so the unique index on user_profile_id does
      # not fire first — only the drift trigger can catch the disagreement).
      other_principal_id = Ecto.UUID.generate()
      {:ok, _} = Dhc.Auth.register_principal_with_id(other_principal_id, %{email: unique_email()})

      other_profile_id = Ecto.UUID.generate()

      _ =
        Repo.query!(
          """
          INSERT INTO user_profiles
            (id, principal_id, first_name, last_name, is_active, date_of_birth,
             gender, phone_number, social_media_consent, created_at, updated_at)
          VALUES ($1, $2, 'Other', 'Profile', true, '1990-01-01',
                  'man (cis)', '+353810000000', 'no', NOW(), NOW())
          """,
          [Ecto.UUID.dump!(other_profile_id), Ecto.UUID.dump!(other_principal_id)]
        )

      # Repoint member_a's MemberProfile at the other profile. member_a.id
      # != other_profile's principal_id → drift, and the profile is not yet
      # linked to any MemberProfile, so the unique index cannot fire first.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "UPDATE member_profiles SET user_profile_id = $1, updated_at = NOW() WHERE id = $2",
            [Ecto.UUID.dump!(other_profile_id), Ecto.UUID.dump!(member_a.principal_id)]
          )
        end

      assert_linkage_drift_violation(error)
    end

    test "UPDATE user_profiles.principal_id to a different Principal raises when a MemberProfile links it" do
      member = MemberFixtures.member_fixture()
      other_principal_id = Ecto.UUID.generate()
      {:ok, _} = Dhc.Auth.register_principal_with_id(other_principal_id, %{email: unique_email()})

      # Repointing the UserProfile's principal_id away from the MemberProfile
      # that links it creates drift (member_profiles.id still points at the old
      # principal, user_profiles.principal_id now disagrees).
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "UPDATE user_profiles SET principal_id = $1, updated_at = NOW() WHERE id = $2",
            [Ecto.UUID.dump!(other_principal_id), Ecto.UUID.dump!(member.profile_id)]
          )
        end

      assert_linkage_drift_violation(error)
    end

    test "UPDATE member_profiles on a non-key column succeeds (trigger ignores it)" do
      # The drift trigger fires on INSERT of member_profiles and on UPDATE of
      # member_profiles.user_profile_id. Updating an unrelated column on an
      # aligned pair must not raise.
      %{principal_id: principal_id} = MemberFixtures.member_fixture()

      result =
        Repo.query!(
          "UPDATE member_profiles SET next_of_kin_name = 'Updated Kin', updated_at = NOW() WHERE id = $1",
          [Ecto.UUID.dump!(principal_id)]
        )

      assert result.num_rows == 1
      :ok
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp assert_linkage_drift_violation(%Postgrex.Error{} = error) do
    assert Map.has_key?(error, :postgres),
           "expected a Postgres error with a constraint, got: #{inspect(error)}"

    constraint = Map.get(error.postgres, :constraint)
    pg_code = Map.get(error.postgres, :code)

    # The trigger raises with ERRCODE 'check_violation' and the fixed
    # constraint name 'linkage_drift_violation'.
    assert pg_code == :check_violation,
           "expected check_violation, got: #{inspect(pg_code)} (#{inspect(error.postgres)})"

    assert constraint == @linkage_drift_constraint,
           "expected linkage drift constraint, got: #{inspect(constraint)} (#{inspect(error.postgres)})"
  end

  defp seed_waitlist_entry do
    waitlist_id = Ecto.UUID.generate()

    _ =
      Repo.query!(
        """
        INSERT INTO waitlist
          (id, email, status, initial_registration_date, last_status_change)
        VALUES ($1, $2, 'waiting', NOW(), NOW())
        """,
        [
          Ecto.UUID.dump!(waitlist_id),
          "waitlist-#{System.unique_integer([:positive])}@example.com"
        ]
      )

    waitlist_id
  end

  defp unique_email, do: "drift-#{System.unique_integer([:positive])}@example.com"
end
