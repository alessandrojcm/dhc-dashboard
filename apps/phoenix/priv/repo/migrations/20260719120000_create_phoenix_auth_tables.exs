defmodule Dhc.Repo.Migrations.CreatePhoenixAuthTables do
  use Ecto.Migration

  # ALE-165 — Phoenix-owned authentication foundation (ADR 0009 / ADR 0010).
  #
  # These tables establish the DHC-owned authentication directory that will
  # replace Supabase Auth after the cutover (ALE-163). They are additive: no
  # existing application foreign keys are repointed here. The cutover
  # migration (M2, ALE-166) will repoint `user_profiles.supabase_user_id`,
  # `user_roles.user_id`, etc. to `principals.id` under a write freeze.
  #
  # Shape follows what `mix phx.gen.auth` emits, adapted to:
  #   - DHC domain language: `principals` (not `users`) — one Principal per
  #     Member; the Supabase UUID is preserved as `id` during cutover.
  #   - Magic-link only (no `hashed_password`). The generator's password
  #     column is intentionally omitted; ALE-165 has no password sign-in path.
  #   - DB-backed opaque sessions tokens (not Phoenix session-only cookies):
  #     `principal_tokens` carries both `"session"` and `"login"` (magic-link)
  #     contexts. Sessions are revocable per-device and have a 30-day absolute
  #     lifetime (enforced in `Dhc.Auth.PrincipalToken`).
  #   - Normalized login email: `citext` + unique index. Normalization happens
  #     in the schema/Ecto layer; the DB just stores the canonical string.
  #   - `created_at`/`updated_at` (NOT `inserted_at`) — matches the production
  #     convention enforced by the `elixir-timestamps-missing-created-at`
  #     ast-grep rule.

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:principals, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      # Authoritative normalized login email. Pending Invitations have no
      # Principal; one Principal per Member. Unique via citext index below.
      add :email, :citext, null: false
      # Set on first magic-link consumption. The generator tracks email
      # confirmation; DHC treats the first successful magic-link login as
      # confirmation (the magic link was sent to this email).
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:principals, [:email])

    # Replaces the generator's `users_tokens`. Carries both magic-link
    # (`context = "login"`) and session (`context = "session"`) tokens.
    # Magic-link tokens are database-hashed (SHA-256); session tokens are
    # random opaque bytes stored hashed too, so a read-only DB leak cannot
    # mint a session.
    create table(:principal_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :principal_id,
          references(:principals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false, inserted_at: :created_at)
    end

    create index(:principal_tokens, [:principal_id])
    # Look up a token by (context, hashed_token) — the only public query shape.
    create unique_index(:principal_tokens, [:context, :token])

    # Rate-limit windows for the magic-link request endpoint. Keyed by
    # `"magic_link:email:<normalized>"` and `"magic_link:ip:<ip>"`. Fixed
    # windows aligned to epoch (15-min for email, 1-hour for IP). DB-backed
    # so the limit is enforced across nodes and is testable through the Ecto
    # sandbox. See `DhcWeb.Plugs.MagicLinkRateLimit` for the policy.
    create table(:auth_rate_limit_windows, primary_key: false) do
      add :key, :text, null: false
      add :window_start, :timestamptz, null: false
      add :count, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:auth_rate_limit_windows, [:key, :window_start])
  end

  def down do
    drop table(:auth_rate_limit_windows)
    drop table(:principal_tokens)
    drop index(:principals, [:email])
    drop table(:principals)
    execute "DROP EXTENSION IF EXISTS citext"
  end
end
