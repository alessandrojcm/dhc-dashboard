defmodule Dhc.Repo.Migrations.Ale282InventoryExpandTargetTables do
  @moduledoc """
  ALE-282 expand: additive target inventory tables and kill-flag storage.

  Purely additive — no existing column, constraint, or row is modified or
  removed, so legacy behavior is untouched and the migration is fully
  reversible. No target command is exposed by this migration; the
  `Dhc.Inventory.TargetFlags` server-side flags (default off) gate every
  future target read/command surface independently.

  Adds (per ALE-272 "Additive database target", as adjusted by the ALE-281
  decision — legacy rows need no preservation, no backfill, no dual-write):

    * `inventory_items.slug` (nullable, unique where present) backed by the
      `inventory_item_slug_seq` sequence. Slugs are minted server-side as
      `item-` plus a zero-padded monotonic number; the column stays nullable
      until the target item slice (ALE-284) starts minting them.
    * `archived_at` (+ `archived_by_principal_id` on items) on
      `inventory_items`, `equipment_categories`, and `containers`.
    * `inventory_property_definitions`, `inventory_property_options`,
      `inventory_item_property_values` (typed properties).
    * `inventory_maintenance_periods` (retained facts, one open per item).
    * `inventory_loans` (retained facts with borrower-history snapshots:
      `item_slug_snapshot`, `item_label_snapshot`,
      `approved_container_path_snapshot`).
    * `inventory_loan_reminders` (durable reminder ledger keyed by
      `(loan_id, recipient_principal_id, kind, due_on_revision)`).

  Every new foreign key uses `ON DELETE RESTRICT` (`:nothing`) so a
  destructive bypass fails at the database. Existing legacy cascades
  (`containers.parent_container_id`, `inventory_history.item_id`) are
  deliberately left untouched here — tightening them would change legacy
  delete behavior; that moves to the contract stage (ALE-289).
  """

  use Ecto.Migration

  def up do
    execute "CREATE SEQUENCE IF NOT EXISTS inventory_item_slug_seq", ""

    alter table(:inventory_items) do
      add :slug, :text
      add :archived_at, :timestamptz
      add :archived_by_principal_id, references(:principals, type: :uuid, on_delete: :nothing)
    end

    create unique_index(:inventory_items, [:slug], where: "slug IS NOT NULL")

    alter table(:equipment_categories) do
      add :archived_at, :timestamptz
    end

    alter table(:containers) do
      add :archived_at, :timestamptz
    end

    # ── Typed property definitions ────────────────────────────────
    create table(:inventory_property_definitions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :category_id, references(:equipment_categories, type: :uuid, on_delete: :nothing),
        null: false

      add :label, :text, null: false
      add :value_type, :text, null: false
      add :required, :boolean, null: false, default: false
      add :identifying_position, :integer
      add :retired_at, :timestamptz

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:inventory_property_definitions, [:category_id])

    execute """
            ALTER TABLE inventory_property_definitions
              ADD CONSTRAINT inventory_property_definitions_value_type_check
              CHECK (value_type IN ('text', 'decimal', 'boolean', 'single_select'))
            """,
            ""

    create unique_index(
             :inventory_property_definitions,
             ["category_id", "lower(label)"],
             name: :inventory_property_definitions_category_label_unique
           )

    create unique_index(
             :inventory_property_definitions,
             [:category_id, :identifying_position],
             where: "identifying_position IS NOT NULL",
             name: :inventory_property_definitions_category_identifying_position_unique
           )

    # ── Single-select options ─────────────────────────────────────
    create table(:inventory_property_options, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :property_definition_id,
          references(:inventory_property_definitions, type: :uuid, on_delete: :nothing),
          null: false

      add :label, :text, null: false
      add :position, :integer, null: false, default: 0
      add :retired_at, :timestamptz

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:inventory_property_options, [:property_definition_id])

    create unique_index(
             :inventory_property_options,
             ["property_definition_id", "lower(label)"],
             name: :inventory_property_options_definition_label_unique
           )

    # ── Typed values (exactly one value column set per row) ───────
    create table(:inventory_item_property_values, primary_key: false) do
      add :item_id, references(:inventory_items, type: :uuid, on_delete: :nothing),
        primary_key: true

      add :property_definition_id,
          references(:inventory_property_definitions, type: :uuid, on_delete: :nothing),
          primary_key: true

      add :text_value, :text
      add :decimal_value, :decimal
      add :boolean_value, :boolean

      add :option_id, references(:inventory_property_options, type: :uuid, on_delete: :nothing)

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    execute """
            ALTER TABLE inventory_item_property_values
              ADD CONSTRAINT inventory_item_property_values_exactly_one_check
              CHECK (
                (CASE WHEN text_value IS NOT NULL THEN 1 ELSE 0 END) +
                (CASE WHEN decimal_value IS NOT NULL THEN 1 ELSE 0 END) +
                (CASE WHEN boolean_value IS NOT NULL THEN 1 ELSE 0 END) +
                (CASE WHEN option_id IS NOT NULL THEN 1 ELSE 0 END) = 1
              )
            """,
            ""

    # ── Retained maintenance periods ──────────────────────────────
    create table(:inventory_maintenance_periods, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :item_id, references(:inventory_items, type: :uuid, on_delete: :nothing), null: false
      add :started_at, :timestamptz, null: false

      add :started_by_principal_id, references(:principals, type: :uuid, on_delete: :nothing),
        null: false

      add :start_reason, :text, null: false
      add :ended_at, :timestamptz
      add :ended_by_principal_id, references(:principals, type: :uuid, on_delete: :nothing)
      add :end_note, :text

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:inventory_maintenance_periods, [:item_id])

    create unique_index(
             :inventory_maintenance_periods,
             [:item_id],
             where: "ended_at IS NULL",
             name: :inventory_maintenance_periods_one_open_per_item
           )

    # ── Retained loans ────────────────────────────────────────────
    create table(:inventory_loans, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :item_id, references(:inventory_items, type: :uuid, on_delete: :nothing), null: false

      add :borrower_principal_id, references(:principals, type: :uuid, on_delete: :nothing),
        null: false

      add :status, :text, null: false
      add :requested_start_on, :date, null: false
      add :requested_due_on, :date, null: false
      add :approved_start_on, :date
      add :approved_due_on, :date
      add :checked_out_at, :timestamptz
      add :returned_at, :timestamptz
      add :decided_at, :timestamptz
      add :decided_by_principal_id, references(:principals, type: :uuid, on_delete: :nothing)
      add :returned_by_principal_id, references(:principals, type: :uuid, on_delete: :nothing)
      add :request_note, :text
      add :decision_note, :text
      # Immutable borrower-history display facts captured at request/approval.
      add :item_slug_snapshot, :text, null: false
      add :item_label_snapshot, :text, null: false
      add :approved_container_path_snapshot, :text

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    execute """
            ALTER TABLE inventory_loans
              ADD CONSTRAINT inventory_loans_status_check
              CHECK (status IN ('requested', 'approved', 'rejected', 'cancelled', 'checked_out', 'returned'))
            """,
            ""

    create index(:inventory_loans, [:item_id])
    create index(:inventory_loans, [:borrower_principal_id])
    create index(:inventory_loans, [:status, :approved_due_on])

    create unique_index(
             :inventory_loans,
             [:item_id, :borrower_principal_id],
             where: "status = 'requested'",
             name: :inventory_loans_one_pending_request_per_item_borrower
           )

    create unique_index(
             :inventory_loans,
             [:item_id],
             where: "status IN ('approved', 'checked_out')",
             name: :inventory_loans_one_active_allocation_per_item
           )

    # ── Durable reminder ledger ───────────────────────────────────
    create table(:inventory_loan_reminders, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :loan_id, references(:inventory_loans, type: :uuid, on_delete: :nothing), null: false

      add :recipient_principal_id, references(:principals, type: :uuid, on_delete: :nothing),
        null: false

      add :kind, :text, null: false
      add :due_on_revision, :integer, null: false, default: 0
      add :scheduled_for, :timestamptz, null: false
      add :delivered_at, :timestamptz

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:inventory_loan_reminders, [:loan_id])
    create index(:inventory_loan_reminders, [:scheduled_for], where: "delivered_at IS NULL")

    create unique_index(
             :inventory_loan_reminders,
             [:loan_id, :recipient_principal_id, :kind, :due_on_revision],
             name: :inventory_loan_reminders_ledger_key_unique
           )
  end

  def down do
    drop table(:inventory_loan_reminders)
    drop table(:inventory_loans)
    drop table(:inventory_maintenance_periods)
    drop table(:inventory_item_property_values)
    drop table(:inventory_property_options)
    drop table(:inventory_property_definitions)

    alter table(:containers) do
      remove :archived_at
    end

    alter table(:equipment_categories) do
      remove :archived_at
    end

    drop index(:inventory_items, [:slug], where: "slug IS NOT NULL")

    alter table(:inventory_items) do
      remove :archived_by_principal_id
      remove :archived_at
      remove :slug
    end

    execute "DROP SEQUENCE IF EXISTS inventory_item_slug_seq", ""
  end
end
