defmodule Dhc.AuthM2CutoverRehearsalTest do
  use Dhc.DataCase, async: false

  import Dhc.AuthMigrationFixtures

  alias Dhc.AuthMigration.M1
  alias Dhc.AuthMigration.M2
  alias Dhc.AuthMigration.M2.AnomalyError
  alias Dhc.Repo

  @post_m2_principal_fk_tables ~w(
    discord_assignment_review_executions
    discord_assignment_stage_executions
    discord_assignment_stage_results
    staged_discord_assignment_audit_events
    staged_discord_assignments
  )

  setup do
    ensure_auth_identities_table!()

    drop_post_m2_linkage_drift_triggers!()
    restore_pre_m2_schema!()

    if column_exists?("user_profiles", "principal_id") do
      M2.rollback!(Repo)
    end

    Repo.query!("DELETE FROM external_identities", [])
    Repo.query!("DELETE FROM principals", [])
    Repo.query!("DELETE FROM auth_migration_audit", [])
    :ok
  end

  test "cuts ownership over to Principals without changing Member UUIDs" do
    member = seed_member(email: "member@example.com")
    assert :ok = M1.run!(Repo)

    assert :ok = M2.run!(Repo)

    assert [[member.auth_user_id, member.auth_user_id]] ==
             rows(
               """
               SELECT up.principal_id::text, ur.principal_id::text
               FROM user_profiles up
               JOIN user_roles ur ON ur.principal_id = up.principal_id
               WHERE up.principal_id = $1
               """,
               [Ecto.UUID.dump!(member.auth_user_id)]
             )

    assert auth_user_foreign_keys() == []
    assert length(application_principal_foreign_keys()) == 17

    assert [["ok", %{"foreign_keys_repointed" => 17, "pending_invitations_deleted" => 0}]] =
             rows("""
             SELECT status, counts
             FROM auth_migration_audit
             WHERE step = 'm2_cutover'
             ORDER BY created_at DESC
             LIMIT 1
             """)
  end

  test "deletes pending Invitations while preserving accepted Invitations" do
    pending = seed_invitation("pending@example.com", "pending")
    accepted_member = seed_member(email: "accepted@example.com")
    accepted = seed_invitation("accepted@example.com", "accepted", accepted_member.auth_user_id)
    assert :ok = M1.run!(Repo)

    assert :ok = M2.run!(Repo)

    assert rows("SELECT id::text FROM invitations ORDER BY id::text") == [[accepted]]
    refute accepted == pending

    new_pending = seed_invitation("new-pending@example.com", "pending")

    assert rows("SELECT id::text FROM invitations WHERE id = $1", [Ecto.UUID.dump!(new_pending)]) ==
             [
               [new_pending]
             ]
  end

  test "aborts before changing ownership when source data drifted after M1" do
    member = seed_member(email: "member@example.com")
    assert :ok = M1.run!(Repo)
    Repo.query!("DELETE FROM principals WHERE id = $1", [Ecto.UUID.dump!(member.auth_user_id)])

    error = assert_raise AnomalyError, fn -> M2.run!(Repo) end

    assert error.class == :principal_reconciliation_mismatch
    assert error.count == 1
    assert column_exists?("user_profiles", "supabase_user_id")
    refute column_exists?("user_profiles", "principal_id")
    assert rows("SELECT count(*) FROM auth_migration_audit WHERE step = 'm2_cutover'") == [[0]]
  end

  test "rolls the ownership contract back for the verified previous release" do
    seed_member(email: "member@example.com")
    assert :ok = M1.run!(Repo)
    assert :ok = M2.run!(Repo)

    assert :ok = M2.rollback!(Repo)

    assert column_exists?("user_profiles", "supabase_user_id")
    assert column_exists?("user_roles", "user_id")
    refute column_exists?("user_profiles", "principal_id")
    assert length(auth_user_foreign_keys()) == 14
    assert application_principal_foreign_keys() == []
  end

  defp seed_invitation(email, status, user_id \\ Ecto.UUID.generate()) do
    id = Ecto.UUID.generate()

    principal_column =
      if column_exists?("invitations", "prospective_principal_id"),
        do: "prospective_principal_id",
        else: "user_id"

    Repo.query!(
      """
      INSERT INTO invitations
        (id, email, #{principal_column}, status, invitation_type, expires_at, created_at, updated_at)
      VALUES ($1, $2, $3, $4::invitation_status, 'standard', NOW() + INTERVAL '1 day', NOW(), NOW())
      """,
      [Ecto.UUID.dump!(id), email, Ecto.UUID.dump!(user_id), status]
    )

    id
  end

  defp auth_user_foreign_keys, do: foreign_keys("auth", "users")

  defp application_principal_foreign_keys do
    foreign_keys("public", "principals")
    |> Enum.reject(fn [table, _constraint] ->
      table in ~w(
        discord_roster_executions
        discord_roster_receipts
        external_identities
        principal_tokens
      ) or table in @post_m2_principal_fk_tables
    end)
  end

  defp foreign_keys(schema, table) do
    rows(
      """
      SELECT conrelid::regclass::text, conname
      FROM pg_constraint
      WHERE contype = 'f'
        AND connamespace = 'public'::regnamespace
        AND confrelid = to_regclass($1)
      ORDER BY conrelid::regclass::text, conname
      """,
      ["#{schema}.#{table}"]
    )
  end

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
