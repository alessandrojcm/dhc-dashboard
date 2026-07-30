defmodule Dhc.AuthM1RehearsalTest do
  use Dhc.DataCase, async: false

  import Dhc.AuthMigrationFixtures

  alias Dhc.AuthMigration.M1
  alias Dhc.AuthMigration.M1.AnomalyError
  alias Dhc.AuthMigration.M2
  alias Dhc.Repo

  setup do
    ensure_auth_identities_table!()

    drop_post_m2_linkage_drift_triggers!()

    if column_exists?("user_profiles", "principal_id") do
      M2.rollback!(Repo)
    end

    # test_helper runs M1 once against an empty database. Each rehearsal test
    # needs to observe only its own target population and audit evidence.
    Repo.query!("DELETE FROM external_identities", [])
    Repo.query!("DELETE FROM principals", [])
    Repo.query!("DELETE FROM auth_migration_audit", [])
    :ok
  end

  describe "successful restored-backup rehearsal" do
    test "preserves UUIDs and creates one Principal for each active or inactive Member" do
      active = seed_member(email: "active@example.com")
      inactive = seed_member(email: "inactive@example.com", is_active: false)

      assert :ok = M1.run!(Repo)

      assert principal_ids() == Enum.sort([active.auth_user_id, inactive.auth_user_id])
      assert principal_email(active.auth_user_id) == "active@example.com"
      assert principal_email(inactive.auth_user_id) == "inactive@example.com"

      assert count("""
             SELECT count(*)
             FROM principals p
             JOIN auth.users u ON u.id = p.id
             JOIN user_profiles up ON up.supabase_user_id = p.id
             JOIN member_profiles mp ON mp.id = p.id AND mp.user_profile_id = up.id
             """) == 2
    end

    test "does not create a Principal for an auth user without a Member profile" do
      seed_auth_user_only("login-only@example.com")

      assert :ok = M1.run!(Repo)
      assert principal_ids() == []
    end

    test "creates a Principal for a magic-link-only Member without requiring Discord" do
      member = seed_member(email: "magic-link@example.com")
      seed_email_identity(member.auth_user_id, "magic-link@example.com")

      assert :ok = M1.run!(Repo)

      assert principal_ids() == [member.auth_user_id]
      assert rows("SELECT count(*) FROM external_identities") == [[0]]
    end

    test "imports Discord subject and metadata without changing authoritative email" do
      member =
        seed_member(
          email: "authoritative@example.com",
          discord: %{
            provider_subject: "160123255573839874",
            email: "discord-metadata@example.com",
            email_verified: true
          }
        )

      assert [["160123255573839874", "160123255573839874", "160123255573839874", false, false]] =
               rows("""
               SELECT provider_id, identity_data->>'sub', identity_data->>'provider_id',
                      (identity_data->>'sub') IS DISTINCT FROM provider_id,
                      (identity_data->>'provider_id') IS DISTINCT FROM provider_id
               FROM auth.identities
               WHERE provider = 'discord'
               """)

      assert :ok = M1.run!(Repo)

      assert principal_email(member.auth_user_id) == "authoritative@example.com"

      assert [["discord", "160123255573839874", metadata]] =
               rows("""
               SELECT provider, provider_subject, metadata
               FROM external_identities
               """)

      assert metadata["email"] == "discord-metadata@example.com"
      assert metadata["email_verified"] == true
    end

    test "imports Discord only, not Supabase email identities" do
      member = seed_member(email: "member@example.com")
      seed_email_identity(member.auth_user_id, "member@example.com")
      seed_discord_identity(member.auth_user_id, provider_subject: "123456789012345678")

      assert :ok = M1.run!(Repo)

      assert rows("SELECT provider FROM external_identities") == [["discord"]]
    end

    test "writes aggregate reconciliation evidence without personal payloads" do
      seed_member(email: "one@example.com")

      seed_member(
        email: "two@example.com",
        discord: %{provider_subject: "223456789012345678", email: "discord@example.com"}
      )

      assert :ok = M1.run!(Repo)

      assert [["ok", counts, detail]] =
               rows("""
               SELECT status, counts, detail
               FROM auth_migration_audit
               WHERE step = 'm1_populate'
               """)

      assert counts == %{
               "source_members" => 2,
               "target_principals" => 2,
               "source_discord_identities" => 1,
               "target_discord_identities" => 1
             }

      evidence = Jason.encode!(counts) <> detail
      refute evidence =~ "one@example.com"
      refute evidence =~ "discord@example.com"
      refute evidence =~ "223456789012345678"
    end

    test "the target uniqueness constraints reject duplicate provider links" do
      first = seed_member(email: "one@example.com")
      second = seed_member(email: "two@example.com")
      assert :ok = M1.run!(Repo)

      insert_external_identity(first.auth_user_id, "same-subject")

      assert_raise Postgrex.Error, fn ->
        insert_external_identity(second.auth_user_id, "same-subject")
      end
    end
  end

  describe "preflight anomaly gates" do
    test "aborts when the GoTrue identities source table is missing" do
      Repo.query!("DROP TABLE auth.identities", [])

      assert_abort(:auth_identities_source_missing)
    end

    test "aborts on an orphan user profile before writing targets" do
      %{profile_id: profile_id, auth_user_id: auth_user_id} = seed_orphan_user_profile()

      error = assert_abort(:orphan_user_profile)

      assert Exception.message(error) =~
               "user_profile #{profile_id} -> auth.users #{auth_user_id} does not exist"

      assert Exception.message(error) =~
               "profiles have a NULL supabase_user_id or reference an auth.users row that does not exist"
    end

    test "aborts when a login-backed profile has no Member profile" do
      member = seed_member(email: "orphan@example.com", with_member_profile: false)

      error = assert_abort(:member_profile_missing)

      assert Exception.message(error) =~
               "user_profile #{member.user_profile_id} -> auth.users #{member.auth_user_id}; roles: member"

      assert Exception.message(error) =~
               "login-backed user_profiles have no member_profiles row linked by user_profile_id"
    end

    test "aborts on a normalized-email collision" do
      seed_member(email: "duplicate@example.com")
      seed_member(email: "DUPLICATE@example.com")

      assert_abort(:principal_email_collision)
    end

    test "aborts on a non-normalized source email" do
      seed_member(email: " MixedCase@example.com ")

      assert_abort(:normalized_email_anomaly)
    end

    test "aborts when Discord provider_id and payload subjects disagree" do
      member = seed_member(email: "member@example.com")

      seed_raw_discord_identity(member.auth_user_id,
        provider_id: "333333333333333333",
        sub: "444444444444444444",
        payload_provider_id: "333333333333333333"
      )

      assert_abort(:inconsistent_provider_subject)
    end

    test "aborts when one Member has repeated Discord identities" do
      member = seed_member(email: "member@example.com")
      seed_discord_identity(member.auth_user_id, provider_subject: "555555555555555551")
      seed_discord_identity(member.auth_user_id, provider_subject: "555555555555555552")

      assert_abort(:discord_repeated_provider_per_owner)
    end

    test "aborts when a Discord provider subject is shared by Members" do
      Repo.query!(
        "ALTER TABLE auth.identities DROP CONSTRAINT identities_provider_id_provider_unique",
        []
      )

      first = seed_member(email: "one@example.com")
      second = seed_member(email: "two@example.com")
      seed_discord_identity(first.auth_user_id, provider_subject: "666666666666666666")
      seed_discord_identity(second.auth_user_id, provider_subject: "666666666666666666")

      assert_abort(:discord_provider_subject_shared)
    end

    test "aborts when a Discord identity owner is missing" do
      Repo.query!(
        "ALTER TABLE auth.identities DROP CONSTRAINT identities_user_id_fkey",
        []
      )

      seed_raw_discord_identity(Ecto.UUID.generate(),
        provider_id: "777777777777777777",
        sub: "777777777777777777",
        payload_provider_id: "777777777777777777"
      )

      assert_abort(:discord_identity_orphan_owner)
    end

    test "aborts when a Discord identity owner is not a Member" do
      owner_id = seed_auth_user_only("not-a-member@example.com")
      seed_discord_identity(owner_id, provider_subject: "888888888888888888")

      assert_abort(:discord_identity_member_missing)
    end
  end

  describe "rollback" do
    test "removes the imported source population and records aggregate evidence" do
      imported =
        seed_member(
          email: "imported@example.com",
          discord: %{provider_subject: "999999999999999999"}
        )

      # Principal born under the ALE-162 lifecycle has no auth.users row and
      # must survive an M1 rollback.
      {:ok, native} =
        Dhc.Auth.register_principal_with_id(Ecto.UUID.generate(), %{email: "native@example.com"})

      assert :ok = M1.run!(Repo)
      assert :ok = M1.rollback!(Repo)

      refute imported.auth_user_id in principal_ids()
      assert native.id in principal_ids()
      assert rows("SELECT count(*) FROM external_identities") == [[0]]

      assert [["ok", %{"source_principals_remaining" => 0}]] =
               rows("""
               SELECT status, counts
               FROM auth_migration_audit
               WHERE step = 'm1_rollback'
               """)
    end
  end

  defp assert_abort(class) do
    error = assert_raise AnomalyError, fn -> M1.run!(Repo) end
    assert error.class == class
    assert error.count > 0
    assert principal_ids() == []
    assert rows("SELECT count(*) FROM external_identities") == [[0]]
    assert rows("SELECT count(*) FROM auth_migration_audit") == [[0]]
    error
  end

  defp seed_auth_user_only(email) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO auth.users (id, aud, role, email, confirmed_at, created_at, updated_at)
      VALUES ($1, 'authenticated', 'authenticated', $2, NOW(), NOW(), NOW())
      """,
      [Ecto.UUID.dump!(id), email]
    )

    id
  end

  defp seed_orphan_user_profile do
    profile_id = Ecto.UUID.generate()
    auth_user_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO user_profiles
        (id, supabase_user_id, first_name, last_name, is_active, date_of_birth,
         gender, phone_number, social_media_consent, created_at, updated_at)
      VALUES ($1, $2, 'Orphan', 'Profile', true, '1990-01-01', 'man (cis)',
              '+353810000000', 'no', NOW(), NOW())
      """,
      [Ecto.UUID.dump!(profile_id), Ecto.UUID.dump!(auth_user_id)]
    )

    %{profile_id: profile_id, auth_user_id: auth_user_id}
  end

  defp seed_email_identity(user_id, email) do
    identity_data = %{"sub" => user_id, "email" => email}

    Repo.query!(
      """
      INSERT INTO auth.identities
        (provider_id, user_id, identity_data, provider, created_at, updated_at)
      VALUES ($1, $2, $3::jsonb, 'email', NOW(), NOW())
      """,
      [user_id, Ecto.UUID.dump!(user_id), identity_data]
    )
  end

  defp seed_raw_discord_identity(user_id, attrs) do
    identity_data = %{
      "sub" => Keyword.fetch!(attrs, :sub),
      "provider_id" => Keyword.fetch!(attrs, :payload_provider_id),
      "email" => "metadata@example.com",
      "email_verified" => true
    }

    Repo.query!(
      """
      INSERT INTO auth.identities
        (provider_id, user_id, identity_data, provider, created_at, updated_at)
      VALUES ($1, $2, $3::jsonb, 'discord', NOW(), NOW())
      """,
      [Keyword.fetch!(attrs, :provider_id), Ecto.UUID.dump!(user_id), identity_data]
    )
  end

  defp insert_external_identity(principal_id, subject) do
    Repo.query!(
      """
      INSERT INTO external_identities
        (id, principal_id, provider, provider_subject, metadata, created_at, updated_at)
      VALUES (gen_random_uuid(), $1, 'discord', $2, '{}'::jsonb, NOW(), NOW())
      """,
      [Ecto.UUID.dump!(principal_id), subject]
    )
  end

  defp principal_ids do
    rows("SELECT id::text FROM principals ORDER BY id::text")
    |> List.flatten()
  end

  defp principal_email(id) do
    assert [[email]] =
             rows("SELECT email::text FROM principals WHERE id = $1", [Ecto.UUID.dump!(id)])

    email
  end

  defp count(sql), do: rows(sql) |> hd() |> hd()

  defp column_exists?(table, column) do
    rows(
      """
      SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
      )
      """,
      [table, column]
    ) == [[true]]
  end

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows
end
