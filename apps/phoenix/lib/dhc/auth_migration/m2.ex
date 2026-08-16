defmodule Dhc.AuthMigration.M2 do
  @moduledoc """
  Transactional M2 ownership cutover from Supabase Auth users to Principals.

  M2 is run under the production write freeze. It validates that M1's source
  and target populations have not drifted, removes pending Invitations, renames
  the two application-facing ownership columns, and repoints every application
  foreign key to `principals.id`.
  """

  defmodule AnomalyError do
    defexception [:class, :count]

    @impl true
    def message(%__MODULE__{class: class, count: count}) do
      "Authentication cutover abort: #{class} (#{count}); restore the write freeze and reconcile before retry"
    end
  end

  # The cutover repoints 17 application FKs. The previously omitted
  # club_activity_registrations.attendance_marked_by FK moves too, while
  # invitations.user_id deliberately remains unconstrained: a pending
  # Invitation owns a fresh future Principal UUID before that Principal exists.
  @ownership_foreign_keys [
    {"waitlist_status_history", "changed_by", "waitlist_status_history_changed_by_fkey",
     :nothing},
    {"user_profiles", "principal_id", "user_profiles_principal_id_fkey", :nothing},
    {"user_roles", "principal_id", "user_roles_principal_id_fkey", :delete_all},
    {"user_audit_log", "user_id", "user_audit_log_user_id_fkey", :nothing},
    {"member_profiles", "id", "member_profiles_id_fkey", :nothing},
    {"settings", "updated_by", "settings_updated_by_fkey", :nothing},
    {"club_activities", "created_by", "club_activities_created_by_fkey", :nothing},
    {"club_activity_interest", "user_id", "club_activity_interest_user_id_fkey", :delete_all},
    {"club_activity_registrations", "attendance_marked_by",
     "club_activity_registrations_attendance_marked_by_fkey", :nothing},
    {"club_activity_refunds", "requested_by", "club_activity_refunds_requested_by_fkey",
     :nothing},
    {"club_activity_refunds", "processed_by", "club_activity_refunds_processed_by_fkey",
     :nothing},
    {"invitations", "created_by", "invitations_created_by_fkey", :nothing},
    {"invitation_processing_logs", "user_id", "invitation_processing_logs_user_id_fkey",
     :delete_all},
    {"containers", "created_by", "containers_created_by_fkey", :nothing},
    {"inventory_items", "created_by", "inventory_items_created_by_fkey", :nothing},
    {"inventory_items", "updated_by", "inventory_items_updated_by_fkey", :nothing},
    {"inventory_history", "changed_by", "inventory_history_changed_by_fkey", :nothing}
  ]

  @legacy_constraint_names %{
    "user_profiles_principal_id_fkey" => "user_profiles_supabase_user_id_fkey",
    "user_roles_principal_id_fkey" => "user_roles_user_id_fkey"
  }

  @already_removed_before_m2 ~w(
    invitations_user_id_fkey
    user_profiles_supabase_user_id_fkey
    member_profiles_id_fkey
    user_roles_user_id_fkey
  )

  @type repo :: module()

  @spec run!(repo()) :: :ok
  def run!(repo) do
    foreign_keys = ownership_foreign_keys(repo)

    validate_reconciliation!(repo)
    validate_referenced_principals!(repo, foreign_keys)

    %{num_rows: pending_deleted} =
      query!(repo, "DELETE FROM invitations WHERE status = 'pending'")

    drop_application_auth_foreign_keys!(repo, foreign_keys)
    rename_ownership_columns!(repo)
    add_foreign_keys!(repo, foreign_keys, "principals")

    counts = %{
      "foreign_keys_repointed" => length(foreign_keys),
      "pending_invitations_deleted" => pending_deleted
    }

    query!(
      repo,
      """
      INSERT INTO auth_migration_audit
        (id, step, status, counts, detail, created_at)
      VALUES
        (gen_random_uuid(), 'm2_cutover', 'ok', $1::jsonb,
         'Application ownership moved to Principals.', NOW())
      """,
      [counts]
    )

    :ok
  end

  @spec rollback!(repo()) :: :ok
  def rollback!(repo) do
    foreign_keys = ownership_foreign_keys(repo)

    drop_foreign_keys!(repo, foreign_keys)
    restore_ownership_columns!(repo)
    add_foreign_keys!(repo, foreign_keys, "auth.users", legacy?: true)
    :ok
  end

  defp validate_reconciliation!(repo) do
    mismatch_count =
      count(repo, """
      SELECT count(*)
      FROM user_profiles up
      JOIN auth.users u ON u.id = up.supabase_user_id
      JOIN member_profiles mp ON mp.id = u.id AND mp.user_profile_id = up.id
      LEFT JOIN principals p ON p.id = u.id AND p.email = lower(btrim(u.email))
      WHERE p.id IS NULL
      """)

    gate!(:principal_reconciliation_mismatch, mismatch_count)

    discord_mismatch_count =
      count(repo, """
      SELECT count(*)
      FROM auth.identities i
      JOIN user_profiles up ON up.supabase_user_id = i.user_id
      LEFT JOIN external_identities ei
        ON ei.principal_id = i.user_id
       AND ei.provider = 'discord'
       AND ei.provider_subject = i.provider_id
      WHERE i.provider = 'discord' AND ei.id IS NULL
      """)

    gate!(:discord_reconciliation_mismatch, discord_mismatch_count)
  end

  defp validate_referenced_principals!(repo, foreign_keys) do
    references =
      foreign_keys
      |> Enum.reject(fn {table, _column, _constraint, _delete} -> table == "invitations" end)
      |> Enum.map_join(" UNION ALL ", fn {table, column, _constraint, _delete} ->
        column = legacy_column(table, column)
        "SELECT #{column} AS principal_id FROM #{table} WHERE #{column} IS NOT NULL"
      end)

    # Accepted Invitations are retained and must resolve. Pending Invitations
    # are deliberately excluded because M2 deletes them after all gates pass.
    invitation_principal_column =
      current_column(repo, "invitations", "prospective_principal_id", "user_id")

    invitation_creator_column =
      current_column(repo, "invitations", "created_by_principal_id", "created_by")

    references =
      references <>
        " UNION ALL SELECT #{invitation_principal_column} FROM invitations WHERE status <> 'pending' AND #{invitation_principal_column} IS NOT NULL" <>
        " UNION ALL SELECT #{invitation_creator_column} FROM invitations WHERE #{invitation_creator_column} IS NOT NULL"

    missing_count =
      count(repo, """
      SELECT count(*)
      FROM (#{references}) refs
      LEFT JOIN principals p ON p.id = refs.principal_id
      LEFT JOIN user_profiles up ON up.supabase_user_id = refs.principal_id
      LEFT JOIN member_profiles mp ON mp.id = refs.principal_id AND mp.user_profile_id = up.id
      WHERE p.id IS NULL OR up.id IS NULL OR mp.id IS NULL
      """)

    gate!(:referenced_principal_missing_member, missing_count)
  end

  defp gate!(_class, 0), do: :ok
  defp gate!(class, count), do: raise(AnomalyError, class: class, count: count)

  defp drop_application_auth_foreign_keys!(repo, foreign_keys) do
    legacy_foreign_keys =
      Enum.map(foreign_keys, fn {table, column, constraint, delete} ->
        legacy_column = legacy_column(table, column)
        legacy_constraint = Map.get(@legacy_constraint_names, constraint, constraint)
        {table, legacy_column, legacy_constraint, delete}
      end)

    drop_foreign_keys!(repo, legacy_foreign_keys)
  end

  defp drop_foreign_keys!(repo, foreign_keys) do
    Enum.each(foreign_keys, fn {table, _column, constraint, _delete} ->
      query!(repo, "ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{constraint}")
    end)
  end

  defp rename_ownership_columns!(repo) do
    query!(repo, "ALTER TABLE user_profiles RENAME COLUMN supabase_user_id TO principal_id")
    query!(repo, "ALTER TABLE user_roles RENAME COLUMN user_id TO principal_id")

    query!(
      repo,
      "ALTER INDEX user_profiles_supabase_user_id_key RENAME TO user_profiles_principal_id_index"
    )

    query!(
      repo,
      "ALTER INDEX idx_user_role RENAME TO user_roles_role_principal_id_id_index"
    )

    query!(
      repo,
      "ALTER TABLE user_roles RENAME CONSTRAINT user_roles_user_id_role_key TO user_roles_principal_id_role_key"
    )
  end

  defp restore_ownership_columns!(repo) do
    query!(repo, "ALTER TABLE user_profiles RENAME COLUMN principal_id TO supabase_user_id")
    query!(repo, "ALTER TABLE user_roles RENAME COLUMN principal_id TO user_id")

    query!(
      repo,
      "ALTER INDEX user_profiles_principal_id_index RENAME TO user_profiles_supabase_user_id_key"
    )

    query!(
      repo,
      "ALTER INDEX user_roles_role_principal_id_id_index RENAME TO idx_user_role"
    )

    query!(
      repo,
      "ALTER TABLE user_roles RENAME CONSTRAINT user_roles_principal_id_role_key TO user_roles_user_id_role_key"
    )
  end

  defp add_foreign_keys!(repo, foreign_keys, target, opts \\ []) do
    legacy? = Keyword.get(opts, :legacy?, false)

    foreign_keys =
      if legacy? do
        Enum.reject(foreign_keys, fn {_table, _column, constraint, _delete} ->
          Map.get(@legacy_constraint_names, constraint, constraint) in @already_removed_before_m2
        end)
      else
        foreign_keys
      end

    Enum.each(foreign_keys, fn {table, column, constraint, delete} ->
      column = if legacy?, do: legacy_column(table, column), else: column

      constraint =
        if legacy?,
          do: Map.get(@legacy_constraint_names, constraint, constraint),
          else: constraint

      on_delete = if delete == :delete_all, do: " ON DELETE CASCADE", else: ""

      query!(repo, """
      ALTER TABLE #{table}
        ADD CONSTRAINT #{constraint}
        FOREIGN KEY (#{column}) REFERENCES #{target}(id)#{on_delete}
      """)
    end)
  end

  defp legacy_column("user_profiles", "principal_id"), do: "supabase_user_id"
  defp legacy_column("user_roles", "principal_id"), do: "user_id"
  defp legacy_column(_table, column), do: column

  defp ownership_foreign_keys(repo) do
    invitation_creator_column =
      current_column(repo, "invitations", "created_by_principal_id", "created_by")

    processing_owner_column =
      current_column(repo, "invitation_processing_logs", "principal_id", "user_id")

    Enum.map(@ownership_foreign_keys, fn
      {"invitations", "created_by", _constraint, delete} ->
        constraint = "invitations_#{invitation_creator_column}_fkey"
        {"invitations", invitation_creator_column, constraint, delete}

      {"invitation_processing_logs", "user_id", _constraint, delete} ->
        constraint = "invitation_processing_logs_#{processing_owner_column}_fkey"
        {"invitation_processing_logs", processing_owner_column, constraint, delete}

      foreign_key ->
        foreign_key
    end)
  end

  defp current_column(repo, table, current, legacy) do
    if count(
         repo,
         "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '#{table}' AND column_name = '#{current}'"
       ) == 1,
       do: current,
       else: legacy
  end

  defp count(repo, sql) do
    %{rows: [[value]]} = query!(repo, sql)
    value
  end

  defp query!(repo, sql, params \\ []), do: Ecto.Adapters.SQL.query!(repo, sql, params)
end
