defmodule Dhc.AuthMigrationFixtures do
  @moduledoc """
  Test helpers for ALE-166 — M1 (Phoenix-auth data migration) rehearsal.

  Seeds a **production-shaped mock population** of `auth.users`,
  `auth.identities`, `user_profiles`, `member_profiles`, and `user_roles`
  that M1 reads from, and provides the operator-facing aggregate counts
  the rehearsal asserts against.

  ## `auth.identities` in the test schema

  `auth.identities` is created by GoTrue at Supabase Auth boot. It exists
  in production and under `supabase start`, but the testcontainers Postgres
  image (ADR 0006) ships an older `auth` schema without it. The rehearsal
  must exercise the Discord import path, so this fixture creates the table
  (if absent) before seeding. Production M1 finds the table already there
  and never creates it — this is test-only scaffolding, not a migration.

  ## Non-personal mock data

  Emails and Discord subjects here are fixtures (`member-<n>@example.com`,
  `10000000000000000<n>`), not real account data. The rehearsal's
  assertions are on counts and UUID-preservation predicates, mirroring the
  spec's "aggregate, non-personal" rehearsal contract
  (`docs/research/ale-149-auth-population-migration-rehearsal.md`).
  """

  alias Dhc.Repo

  @doc """
  Ensures `auth.identities` exists in the test schema.

  Creates the table if GoTrue has not. Mirrors the production GoTrue shape
  (`provider_id`, `user_id`, `identity_data` jsonb, `provider`, `email`
  generated column, `id` PK, `(provider_id, provider)` unique) closely
  enough that M1's gates and import read it correctly. Idempotent: a
  no-op if the table already exists (production-like envs).
  """
  def ensure_auth_identities_table! do
    repo().query!(auth_identities_table_sql(), [])
    repo().query!(auth_identities_index_sql(), [])

    :ok
  end

  @doc false
  def auth_identities_table_sql do
    """
    CREATE TABLE IF NOT EXISTS auth.identities (
      provider_id text NOT NULL,
      user_id uuid NOT NULL,
      identity_data jsonb NOT NULL,
      provider text NOT NULL,
      last_sign_in_at timestamptz,
      created_at timestamptz,
      updated_at timestamptz,
      email text GENERATED ALWAYS AS (lower(identity_data ->> 'email'::text)) STORED,
      id uuid NOT NULL DEFAULT gen_random_uuid(),
      CONSTRAINT identities_pkey PRIMARY KEY (id),
      CONSTRAINT identities_provider_id_provider_unique UNIQUE (provider_id, provider),
      CONSTRAINT identities_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES auth.users(id) ON DELETE CASCADE
    )
    """
  end

  @doc false
  def auth_identities_index_sql do
    "CREATE INDEX IF NOT EXISTS identities_user_id_idx ON auth.identities USING btree (user_id)"
  end

  @doc """
  Drops the ALE-180 linkage-drift constraint triggers and function if they
  exist.

  The M1/M2 rehearsal tests simulate a restored **pre-M2 backup** — a
  production snapshot taken before the cutover. ALE-180 ships *after* M2, so
  a genuine pre-M2 backup would not carry these triggers. The testcontainers
  harness migrates the whole stack from zero, so the triggers are present in
  the test schema; the rehearsal must drop them to faithfully model the
  restored-backup state. Without this, the triggers' function body (which
  references `user_profiles.principal_id`, the post-M2 column name) fails
  with `undefined_column` once M2 is rolled back to the `supabase_user_id`
  column.

  Idempotent: a no-op when the triggers/function are absent.
  """
  def drop_post_m2_linkage_drift_triggers! do
    # `DROP TRIGGER IF EXISTS` handles both regular and constraint triggers;
    # `DROP CONSTRAINT TRIGGER` does not support IF EXISTS on this Postgres.
    repo().query!(
      "DROP TRIGGER IF EXISTS user_profiles_linkage_drift_update_principal_id ON user_profiles",
      []
    )

    repo().query!(
      "DROP TRIGGER IF EXISTS member_profiles_linkage_drift_update_user_profile_id ON member_profiles",
      []
    )

    repo().query!(
      "DROP TRIGGER IF EXISTS member_profiles_linkage_drift_insert ON member_profiles",
      []
    )

    repo().query!("DROP FUNCTION IF EXISTS verify_linkage_drift()", [])
    :ok
  end

  @doc """
  Restores schema objects changed by migrations that shipped after M2.

  The rehearsal starts from a pre-M2 backup, while testcontainers migrates the
  database through ALE-186 first. Recreate the empty history table, remove the
  later Notification ownership FK, and restore the old ownership column names
  before `M2.rollback!/1` rebuilds the legacy auth foreign keys.
  """
  def restore_pre_m2_schema! do
    repo().query!(
      """
      CREATE TABLE IF NOT EXISTS waitlist_status_history (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        waitlist_id uuid REFERENCES waitlist(id),
        old_status waitlist_status,
        new_status waitlist_status NOT NULL,
        changed_at timestamptz DEFAULT NOW(),
        changed_by uuid REFERENCES principals(id),
        notes text
      )
      """,
      []
    )

    repo().query!(
      """
      DO $$
      BEGIN
        ALTER TABLE notifications
          DROP CONSTRAINT IF EXISTS notifications_principal_id_fkey;

        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name = 'notifications'
            AND column_name = 'principal_id'
        ) THEN
          ALTER TABLE notifications RENAME COLUMN principal_id TO user_id;
        END IF;

        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name = 'user_audit_log'
            AND column_name = 'principal_id'
        ) THEN
          ALTER TABLE user_audit_log RENAME COLUMN principal_id TO user_id;
        END IF;
      END
      $$
      """,
      []
    )

    :ok
  end

  @doc """
  Inserts a production-shaped Member row: `auth.users` + `user_profiles`
  + `member_profiles` + `user_roles` (member role), all keyed by the same
  UUID. Returns a map with the shared UUID and the fixture inputs.

  ## Options

    * `:auth_user_id` — override the shared UUID (default: generated)
    * `:email` — override the auth.users email (default: unique fixture email)
    * `:is_active` — user_profiles.is_active (default: `true`)
    * `:confirmed_at` — auth.users.confirmed_at (default: `now()`)
    * `:with_member_role` — grant the `member` role (default: `true`)
    * `:with_member_profile` — insert a `member_profiles` row (default:
      `true`; set `false` to model an orphan user_profiles row — the
      ALE-149 "active linked profiles without a member_profiles row" case)
    * `:discord` — `false` | `%{provider_subject: binary, email: binary,
      email_verified: boolean}`. When present, also inserts a Discord
      `auth.identities` row for this user. Default: `false` (email-only
      member, the ALE-149 majority shape).
  """
  def seed_member(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    auth_user_id = Map.get(attrs, :auth_user_id) || Ecto.UUID.generate()
    user_profile_id = Ecto.UUID.generate()
    email = Map.get(attrs, :email) || unique_email()

    confirmed_at =
      Map.get(attrs, :confirmed_at) || DateTime.utc_now() |> DateTime.truncate(:second)

    is_active = Map.get(attrs, :is_active, true)
    with_member_role = Map.get(attrs, :with_member_role, true)
    with_member_profile = Map.get(attrs, :with_member_profile, true)
    discord = Map.get(attrs, :discord, false)

    # auth.users — raw insert (Supabase-owned; no Ecto schema).
    repo().query!(
      """
      INSERT INTO auth.users (id, aud, role, email, confirmed_at, created_at, updated_at)
      VALUES ($1, 'authenticated', 'authenticated', $2, $3, NOW(), NOW())
      """,
      [Ecto.UUID.dump!(auth_user_id), email, DateTime.truncate(confirmed_at, :second)]
    )

    # user_profiles — raw insert (matches the baseline migration shape).
    # We bypass the Ecto schema to control the exact row shape the
    # rehearsal needs (e.g. inserting without a member_profiles row for
    # the orphan case).
    repo().query!(
      """
      INSERT INTO user_profiles
        (id, supabase_user_id, first_name, last_name, is_active,
         date_of_birth, gender, phone_number, social_media_consent,
         customer_id, created_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(user_profile_id),
        Ecto.UUID.dump!(auth_user_id),
        Map.get(attrs, :first_name, "Mock"),
        Map.get(attrs, :last_name, "Member"),
        is_active,
        ~D[1990-01-01],
        "man (cis)",
        "+353810000000",
        "no",
        "cus_#{System.unique_integer([:positive])}"
      ]
    )

    if with_member_profile do
      repo().query!(
        """
        INSERT INTO member_profiles
          (id, user_profile_id, next_of_kin_name, next_of_kin_phone,
           preferred_weapon, membership_start_date, insurance_form_submitted,
           additional_data, created_at, updated_at)
        SELECT $1, up.id, 'Next of Kin', '+353820000000',
               ARRAY['longsword']::preferred_weapon[], NOW(), false, '{}'::jsonb, NOW(), NOW()
        FROM user_profiles up WHERE up.supabase_user_id = $2
        """,
        [Ecto.UUID.dump!(auth_user_id), Ecto.UUID.dump!(auth_user_id)]
      )
    end

    if with_member_role do
      repo().query!(
        """
        INSERT INTO user_roles (user_id, role) VALUES ($1, 'member')
        """,
        [Ecto.UUID.dump!(auth_user_id)]
      )
    end

    if discord do
      seed_discord_identity(auth_user_id, discord)
    end

    %{
      auth_user_id: auth_user_id,
      user_profile_id: user_profile_id,
      email: email,
      discord: discord
    }
  end

  @doc """
  Inserts a Discord `auth.identities` row for `auth_user_id`. `discord` is a
  map with `:provider_subject`, `:email`, `:email_verified`. Defaults produce
  a consistent row whose `provider_id`, `identity_data->>'sub'`, and
  `identity_data->>'provider_id'` all agree (the spec's import contract).
  """
  def seed_discord_identity(auth_user_id, discord \\ %{}) do
    discord = Enum.into(discord, %{})
    provider_subject = Map.get(discord, :provider_subject) || unique_discord_subject()
    email = Map.get(discord, :email) || unique_email()
    email_verified = Map.get(discord, :email_verified, true)

    identity_data = %{
      "sub" => provider_subject,
      "provider_id" => provider_subject,
      "email" => email,
      "email_verified" => email_verified,
      "full_name" => "mock-discord-user",
      "picture" => "https://example.com/avatar.png"
    }

    repo().query!(
      """
      INSERT INTO auth.identities
        (provider_id, user_id, identity_data, provider, created_at, updated_at)
      VALUES ($1, $2, $3::jsonb, 'discord', NOW(), NOW())
      """,
      [provider_subject, Ecto.UUID.dump!(auth_user_id), identity_data]
    )

    :ok
  end

  # ── aggregate helpers (the operator's rehearsal-eye view) ────────────────
  # These return counts, never personal identifiers — mirrors the spec's
  # "aggregate, non-personal" rehearsal contract. The M1 rehearsal test
  # asserts against these, not against any row's email or provider subject.

  @doc "Count of auth.users rows joined to a user_profiles row — M1's principal source population."
  def count_source_auth_users_with_profile do
    %{rows: [[n]]} =
      repo().query!(
        """
        SELECT count(*) FROM auth.users u
        INNER JOIN user_profiles up ON up.supabase_user_id = u.id
        """,
        []
      )

    n
  end

  @doc "Count of Discord auth.identities rows whose owner has a user_profiles row — M1's Discord source population."
  def count_source_discord_identities do
    %{rows: [[n]]} =
      repo().query!(
        """
        SELECT count(*) FROM auth.identities i
        INNER JOIN auth.users u ON u.id = i.user_id
        INNER JOIN user_profiles up ON up.supabase_user_id = u.id
        WHERE i.provider = 'discord'
        """,
        []
      )

    n
  end

  defp repo, do: Repo

  defp unique_email, do: "mock-#{System.unique_integer([:positive])}@example.com"

  defp unique_discord_subject do
    # 17-18 digit numeric string, like Discord's real user ids.
    "10000000000000000" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
