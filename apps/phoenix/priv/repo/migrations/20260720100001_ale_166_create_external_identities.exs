defmodule Dhc.Repo.Migrations.Ale166CreateExternalIdentities do
  use Ecto.Migration

  @moduledoc """
  ALE-166 — `external_identities` table (slice 4 of
  docs/auth-migration-specification.md; target contract section "Principal,
  identity, and access").

  ## Why this exists

  The spec fixes that a Discord account is identified by its **immutable
  provider subject**, not its email/username/avatar. One provider subject is
  unique across Principals, and one Principal can have at most one identity
  per provider. M1 (`20260720100002_ale_166_m1_populate_principal_identities.exs`)
  populates this table from Supabase's `auth.identities` (Discord only);
  ALE-167 adds the runtime Assent callback that writes here on first
  Discord sign-in. ALE-166 ships the schema + M1 import so the cutover
  rehearsal proves the population path; ALE-167 ships the live sign-in path.

  ## Shape

    * `provider` — `"discord"` today (the only OAuth provider DHC uses).
    * `provider_subject` — the immutable, provider-scoped subject string
      (Discord's user id). The binding key.
    * `principal_id` — FK to `principals.id`. One Principal per Member;
      one identity per provider per Principal.
    * `metadata` — JSONB. Discord-reported email, username, avatar,
      `email_verified`. **Metadata only** — never authoritative. The spec
      forbids using it to overwrite the normalized login email or to
      re-link an identity.

  Unique constraints enforce the two invariants from the spec:

    * `unique_external_identities_provider_subject` on `(provider,
      provider_subject)` — one provider subject maps to at most one
      Principal.
    * `unique_external_identities_principal_provider` on `(principal_id,
      provider)` — one identity per provider per Principal.

  `created_at`/`updated_at` (NOT `inserted_at`) — matches the production
  timestamp convention enforced by the `elixir-timestamps-missing-created-at`
  ast-grep rule.
  """

  @timestamp_type :timestamptz

  def up do
    create table(:external_identities, primary_key: false) do
      add :id, :uuid,
        primary_key: true,
        default: fragment("gen_random_uuid()")

      add :principal_id,
          references(:principals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider, :text, null: false
      add :provider_subject, :text, null: false
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: @timestamp_type, inserted_at: :created_at)
    end

    create unique_index(:external_identities, [:provider, :provider_subject],
             name: "unique_external_identities_provider_subject"
           )

    create unique_index(:external_identities, [:principal_id, :provider],
             name: "unique_external_identities_principal_provider"
           )

    create index(:external_identities, [:principal_id])
  end

  def down do
    drop index(:external_identities, [:principal_id])

    drop unique_index(:external_identities, [:principal_id, :provider],
           name: "unique_external_identities_principal_provider"
         )

    drop unique_index(:external_identities, [:provider, :provider_subject],
           name: "unique_external_identities_provider_subject"
         )

    drop table(:external_identities)
  end
end
