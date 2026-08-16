defmodule Dhc.Repo.Migrations.CreateAuthMigrationAudit do
  use Ecto.Migration

  @moduledoc """
  ALE-166 — `auth_migration_audit` table (slice 4 of
  docs/auth-migration-specification.md).

  ## Why this exists

  The cutover runbook (slice 4 / slice 5 of the spec) requires the migration
  itself to write **aggregate, non-personal** evidence that:

    * M1 ran against a known source population (one row, counts only);
    * every successful M1/M2 reconciliation produced durable evidence;
    * reconciliation output exists for the operator's seven-day observation
      window and the 13-month operational-evidence retention requirement.

  `auth_migration_audit` is that evidence trail. It is written by M1
  (`20260720100002_populate_principal_identities.exs`) and read
  by M2's reconciliation step; it is **not** written by any runtime auth
  path. No personal authentication payload (email, provider subject, token
  material) is ever stored here — only counts, anomaly class names, and
  timestamps. An anomaly raised inside M1 rolls back the entire migration,
  including any attempted audit insert; its aggregate class/count is emitted
  by the migration error instead. The table records successful reconciliation
  and explicit rollback evidence.

  ## Shape

  One row per migration step. `step` identifies the phase (`"m1_populate"`,
  `"m1_abort"`, `"m2_reconcile"`, `"m2_repoint"`, …). `status` is
  `"ok"` or `"aborted"`. `counts` is a JSONB map of aggregate population
  counters (e.g. `{"source_auth_users": 312, "principals_inserted": 312,
  "discord_identities_imported": 1}`). `anomaly_class` is `NULL` for the ok
  path and is reserved for an operator-recorded abort outside the failed
  transaction
  (`"orphan_user_profile"`, `"principal_email_collision"`,
  `"inconsistent_provider_subject"`, `"normalized_email_anomaly"`).
  `detail` carries a short operator-facing message; never PII.

  `created_at` only — the audit row is immutable once written; there is no
  `updated_at` because the audit trail is append-only.
  """

  # `created_at` only — no `updated_at`. Matches the spec's append-only audit
  # trail requirement. Uses `:timestamptz` to match the rest of the auth
  # migrations' timestamp convention.
  @timestamp_type :timestamptz

  def up do
    create table(:auth_migration_audit, primary_key: false) do
      add :id, :uuid,
        primary_key: true,
        default: fragment("gen_random_uuid()")

      # `"m1_populate"`, `"m1_abort"`, `"m2_reconcile"`, `"m2_repoint"`, …
      add :step, :text, null: false
      # `"ok"` or `"aborted"`.
      add :status, :text, null: false

      # Aggregate population counters (non-personal). NULL on the abort path
      # when the abort precedes population.
      add :counts, :map

      # NULL on the ok path; reserved for operator-recorded abort evidence
      # outside the failed migration transaction. No affected-row list is
      # stored (no exclusion-manifest path, per the spec).
      add :anomaly_class, :text

      # Short operator-facing message. Never carries PII, token material, or
      # account identifiers.
      add :detail, :text

      timestamps(type: @timestamp_type, updated_at: false, inserted_at: :created_at)
    end

    # Operator queries the audit trail by step / status / anomaly_class.
    create index(:auth_migration_audit, [:step, :status])
    create index(:auth_migration_audit, [:anomaly_class])
    create index(:auth_migration_audit, [:created_at])
  end

  def down do
    drop index(:auth_migration_audit, [:created_at])
    drop index(:auth_migration_audit, [:anomaly_class])
    drop index(:auth_migration_audit, [:step, :status])
    drop table(:auth_migration_audit)
  end
end
