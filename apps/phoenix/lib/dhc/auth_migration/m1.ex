defmodule Dhc.AuthMigration.M1 do
  @moduledoc """
  Additive M1 population and reconciliation for ALE-166.

  M1 copies existing Member login identities from Supabase Auth into the
  Phoenix-owned authentication tables without changing application foreign
  keys. All anomaly checks run before the first write. A failed check raises
  `AnomalyError`, allowing the enclosing Ecto migration transaction to roll
  back without persisting a partial population.

  Audit output contains counts and anomaly class names only. It never stores
  emails, provider subjects, UUIDs, identity payloads, or token material.
  """

  defmodule AnomalyError do
    defexception [:class, :count, :detail]

    @impl true
    def message(%__MODULE__{class: class, count: count, detail: detail}) do
      base =
        "ALE-166 M1 abort: #{class} (#{count}); repair source data and rerun — " <>
          "no exclusion manifest is supported"

      if detail, do: base <> "\n" <> detail, else: base
    end
  end

  @type repo :: module()

  @doc "Runs all preflight gates, population statements, and reconciliation."
  @spec run!(repo()) :: :ok
  def run!(repo) do
    require_auth_identities!(repo)

    principal_gates!(repo)
    discord_gates!(repo)

    query!(repo, populate_principals_sql())
    query!(repo, populate_external_identities_sql())

    counts = reconciliation_counts(repo)
    reconcile!(counts)
    write_audit!(repo, counts)
    :ok
  end

  @doc "Reverts only rows in M1's Supabase-backed source population."
  @spec rollback!(repo()) :: :ok
  def rollback!(repo) do
    query!(repo, """
    DELETE FROM external_identities ei
    USING auth.users u, user_profiles up
    WHERE ei.principal_id = u.id
      AND up.supabase_user_id = u.id
      AND ei.provider = 'discord'
    """)

    query!(repo, """
    DELETE FROM principals p
    USING auth.users u, user_profiles up
    WHERE p.id = u.id
      AND up.supabase_user_id = u.id
    """)

    query!(repo, """
    INSERT INTO auth_migration_audit
      (id, step, status, counts, detail, created_at)
    VALUES
      (gen_random_uuid(), 'm1_rollback', 'ok',
       jsonb_build_object(
         'source_principals_remaining', (
           SELECT count(*) FROM principals p
           JOIN user_profiles up ON up.supabase_user_id = p.id
           JOIN auth.users u ON u.id = p.id
         ),
         'source_discord_identities_remaining', (
           SELECT count(*) FROM external_identities ei
           JOIN auth.users u ON u.id = ei.principal_id
           JOIN user_profiles up ON up.supabase_user_id = u.id
           WHERE ei.provider = 'discord'
         )
       ),
       'M1 source population removed.', NOW())
    """)

    :ok
  end

  defp principal_gates!(repo) do
    orphan_user_profile_gate!(repo)

    member_profile_missing_gate!(repo)

    gate!(repo, :member_uuid_mismatch, """
    SELECT count(*)
    FROM member_profiles mp
    JOIN user_profiles up ON up.id = mp.user_profile_id
    WHERE mp.id <> up.supabase_user_id
    """)

    # Collision runs before normalization so case/whitespace variants are
    # reported as a collision rather than as two generic normalization errors.
    gate!(repo, :principal_email_collision, """
    SELECT count(*) FROM (
      SELECT normalized_email
      FROM (
        SELECT lower(btrim(u.email)) AS normalized_email, count(*) AS owners
        FROM auth.users u
        JOIN user_profiles up ON up.supabase_user_id = u.id
        GROUP BY lower(btrim(u.email))
      ) source_collisions
      WHERE owners > 1

      UNION ALL

      SELECT lower(btrim(u.email))
      FROM auth.users u
      JOIN user_profiles up ON up.supabase_user_id = u.id
      JOIN principals p ON p.email = lower(btrim(u.email)) AND p.id <> u.id
    ) collisions
    """)

    gate!(repo, :normalized_email_anomaly, """
    SELECT count(*)
    FROM auth.users u
    JOIN user_profiles up ON up.supabase_user_id = u.id
    WHERE u.email IS NULL
       OR btrim(u.email) = ''
       OR lower(btrim(u.email)) <> u.email
    """)

    gate!(repo, :existing_principal_mismatch, """
    SELECT count(*)
    FROM auth.users u
    JOIN user_profiles up ON up.supabase_user_id = u.id
    JOIN principals p ON p.id = u.id
    WHERE p.email <> lower(btrim(u.email))
    """)
  end

  defp discord_gates!(repo) do
    gate!(repo, :inconsistent_provider_subject, """
    SELECT count(*)
    FROM auth.identities i
    WHERE i.provider = 'discord'
      AND (
        (i.identity_data->>'sub') IS DISTINCT FROM i.provider_id
        OR (i.identity_data->>'provider_id') IS DISTINCT FROM i.provider_id
      )
    """)

    gate!(repo, :discord_identity_orphan_owner, """
    SELECT count(*)
    FROM auth.identities i
    LEFT JOIN auth.users u ON u.id = i.user_id
    WHERE i.provider = 'discord' AND u.id IS NULL
    """)

    gate!(repo, :discord_identity_member_missing, """
    SELECT count(*)
    FROM auth.identities i
    JOIN auth.users u ON u.id = i.user_id
    LEFT JOIN user_profiles up ON up.supabase_user_id = u.id
    WHERE i.provider = 'discord' AND up.id IS NULL
    """)

    gate!(repo, :discord_provider_subject_shared, """
    SELECT count(*) FROM (
      SELECT provider_id
      FROM auth.identities
      WHERE provider = 'discord'
      GROUP BY provider_id
      HAVING count(DISTINCT user_id) > 1
    ) collisions
    """)

    gate!(repo, :discord_repeated_provider_per_owner, """
    SELECT count(*) FROM (
      SELECT user_id
      FROM auth.identities
      WHERE provider = 'discord'
      GROUP BY user_id
      HAVING count(*) > 1
    ) collisions
    """)

    gate!(repo, :existing_external_identity_mismatch, """
    SELECT count(*)
    FROM auth.identities i
    JOIN external_identities ei
      ON (ei.principal_id = i.user_id AND ei.provider = i.provider)
      OR (ei.provider = i.provider AND ei.provider_subject = i.provider_id)
    WHERE i.provider = 'discord'
      AND (
        ei.principal_id IS DISTINCT FROM i.user_id
        OR ei.provider_subject IS DISTINCT FROM i.provider_id
      )
    """)
  end

  defp gate!(repo, class, sql) do
    anomaly_count = count(repo, sql)

    if anomaly_count > 0 do
      raise AnomalyError, class: class, count: anomaly_count
    end
  end

  defp orphan_user_profile_gate!(repo) do
    anomaly_count =
      count(repo, """
      SELECT count(*)
      FROM user_profiles up
      LEFT JOIN auth.users u ON u.id = up.supabase_user_id
      WHERE u.id IS NULL
      """)

    if anomaly_count > 0 do
      %{rows: samples} =
        query!(repo, """
        SELECT up.id::text, COALESCE(up.supabase_user_id::text, 'NULL')
        FROM user_profiles up
        LEFT JOIN auth.users u ON u.id = up.supabase_user_id
        WHERE u.id IS NULL
        ORDER BY up.id
        LIMIT 10
        """)

      sample_lines =
        Enum.map_join(samples, "\n", fn
          [profile_id, "NULL"] ->
            "  user_profile #{profile_id} -> supabase_user_id is NULL"

          [profile_id, missing_auth_user_id] ->
            "  user_profile #{profile_id} -> auth.users #{missing_auth_user_id} does not exist"
        end)

      omitted = anomaly_count - length(samples)
      omitted_line = if omitted > 0, do: "\n  ... and #{omitted} more", else: ""

      detail =
        "Reason: these profiles have a NULL supabase_user_id or reference an auth.users row that does not exist.\n" <>
          "Affected rows (up to 10):\n" <>
          sample_lines <>
          omitted_line <>
          "\nInspect all with:\n" <>
          "  SELECT up.id, up.supabase_user_id FROM user_profiles up " <>
          "LEFT JOIN auth.users u ON u.id = up.supabase_user_id WHERE u.id IS NULL;"

      raise AnomalyError,
        class: :orphan_user_profile,
        count: anomaly_count,
        detail: detail
    end
  end

  defp member_profile_missing_gate!(repo) do
    anomaly_count =
      count(repo, """
      SELECT count(*)
      FROM user_profiles up
      JOIN auth.users u ON u.id = up.supabase_user_id
      LEFT JOIN member_profiles mp ON mp.user_profile_id = up.id
      WHERE mp.id IS NULL
      """)

    if anomaly_count > 0 do
      %{rows: samples} =
        query!(repo, """
        SELECT up.id::text, u.id::text,
               COALESCE(string_agg(DISTINCT ur.role::text, ', ' ORDER BY ur.role::text), 'no roles')
        FROM user_profiles up
        JOIN auth.users u ON u.id = up.supabase_user_id
        LEFT JOIN member_profiles mp ON mp.user_profile_id = up.id
        LEFT JOIN user_roles ur ON ur.user_id = u.id
        WHERE mp.id IS NULL
        GROUP BY up.id, u.id
        ORDER BY up.id
        LIMIT 10
        """)

      sample_lines =
        Enum.map_join(samples, "\n", fn [profile_id, auth_user_id, roles] ->
          "  user_profile #{profile_id} -> auth.users #{auth_user_id}; roles: #{roles}"
        end)

      omitted = anomaly_count - length(samples)
      omitted_line = if omitted > 0, do: "\n  ... and #{omitted} more", else: ""

      detail =
        "Reason: these login-backed user_profiles have no member_profiles row linked by user_profile_id.\n" <>
          "Affected rows (up to 10):\n" <>
          sample_lines <>
          omitted_line <>
          "\nInspect all with:\n" <>
          "  SELECT up.id, up.supabase_user_id, array_agg(ur.role) AS roles " <>
          "FROM user_profiles up JOIN auth.users u ON u.id = up.supabase_user_id " <>
          "LEFT JOIN member_profiles mp ON mp.user_profile_id = up.id " <>
          "LEFT JOIN user_roles ur ON ur.user_id = u.id WHERE mp.id IS NULL " <>
          "GROUP BY up.id, up.supabase_user_id;"

      raise AnomalyError,
        class: :member_profile_missing,
        count: anomaly_count,
        detail: detail
    end
  end

  defp reconciliation_counts(repo) do
    source_principals =
      count(repo, """
      SELECT count(*)
      FROM auth.users u
      JOIN user_profiles up ON up.supabase_user_id = u.id
      JOIN member_profiles mp ON mp.id = u.id AND mp.user_profile_id = up.id
      """)

    target_principals =
      count(repo, """
      SELECT count(*)
      FROM principals p
      JOIN auth.users u ON u.id = p.id
      JOIN user_profiles up ON up.supabase_user_id = u.id
      JOIN member_profiles mp ON mp.id = u.id AND mp.user_profile_id = up.id
      """)

    source_discord =
      count(repo, """
      SELECT count(*)
      FROM auth.identities i
      JOIN user_profiles up ON up.supabase_user_id = i.user_id
      WHERE i.provider = 'discord'
      """)

    target_discord =
      count(repo, """
      SELECT count(*)
      FROM external_identities ei
      JOIN auth.users u ON u.id = ei.principal_id
      JOIN user_profiles up ON up.supabase_user_id = u.id
      WHERE ei.provider = 'discord'
      """)

    %{
      "source_members" => source_principals,
      "target_principals" => target_principals,
      "source_discord_identities" => source_discord,
      "target_discord_identities" => target_discord
    }
  end

  defp reconcile!(%{
         "source_members" => principals,
         "target_principals" => principals,
         "source_discord_identities" => identities,
         "target_discord_identities" => identities
       }),
       do: :ok

  defp reconcile!(counts) do
    mismatches =
      (counts["source_members"] - counts["target_principals"])
      |> abs()
      |> Kernel.+(abs(counts["source_discord_identities"] - counts["target_discord_identities"]))

    raise AnomalyError, class: :reconciliation_mismatch, count: mismatches
  end

  defp write_audit!(repo, counts) do
    query!(
      repo,
      """
      INSERT INTO auth_migration_audit
        (id, step, status, counts, detail, created_at)
      VALUES
        (gen_random_uuid(), 'm1_populate', 'ok', $1::jsonb,
         'M1 source and target aggregates reconciled.', NOW())
      """,
      [counts]
    )
  end

  defp populate_principals_sql do
    """
    INSERT INTO principals (id, email, confirmed_at, created_at, updated_at)
    SELECT u.id, lower(btrim(u.email)), u.confirmed_at, NOW(), NOW()
    FROM auth.users u
    JOIN user_profiles up ON up.supabase_user_id = u.id
    JOIN member_profiles mp ON mp.id = u.id AND mp.user_profile_id = up.id
    ON CONFLICT (id) DO NOTHING
    """
  end

  defp populate_external_identities_sql do
    """
    INSERT INTO external_identities
      (id, principal_id, provider, provider_subject, metadata, created_at, updated_at)
    SELECT
      gen_random_uuid(), i.user_id, 'discord', i.provider_id,
      jsonb_build_object(
        'email', i.identity_data->>'email',
        'email_verified', i.identity_data->'email_verified',
        'username', i.identity_data->>'full_name',
        'avatar_url', i.identity_data->>'picture'
      ),
      NOW(), NOW()
    FROM auth.identities i
    JOIN principals p ON p.id = i.user_id
    WHERE i.provider = 'discord'
    ON CONFLICT (provider, provider_subject) DO NOTHING
    """
  end

  defp require_auth_identities!(repo) do
    %{rows: [[exists?]]} = query!(repo, "SELECT to_regclass('auth.identities') IS NOT NULL")

    unless exists? do
      raise AnomalyError, class: :auth_identities_source_missing, count: 1
    end
  end

  defp count(repo, sql) do
    %{rows: [[value]]} = query!(repo, sql)
    value
  end

  defp query!(repo, sql, params \\ []), do: Ecto.Adapters.SQL.query!(repo, sql, params)
end
