defmodule Dhc.Repo.Migrations.AddLockVersionToMutableSchemas do
  use Ecto.Migration

  @moduledoc """
  ALE-265 Phase 1.1: optimistic-concurrency version witness.

  Adds `lock_version` (integer, NOT NULL, default 1) to every mutable schema
  — inventory items/containers/categories, workshops (`club_activities`) and
  registrations, waitlist entries, member + user profiles, and settings.

  Payment, refund, and durable workflow tables are intentionally excluded
  (Stripe-adjacent flows are out of scope for optimistic locking).

  Existing rows backfill to 1 via the column default; every subsequent
  update bumps the version (see `Ecto.Changeset.optimistic_lock/3` wiring in
  the contexts). See ADR 0023 for the contract.
  """

  @mutable_tables ~w(
    inventory_items
    containers
    equipment_categories
    club_activities
    club_activity_registrations
    waitlist
    user_profiles
    member_profiles
    settings
  )

  def up do
    Enum.each(@mutable_tables, fn table ->
      alter table(table) do
        add :lock_version, :integer, null: false, default: 1
      end
    end)
  end

  def down do
    Enum.each(@mutable_tables, fn table ->
      alter table(table) do
        remove :lock_version
      end
    end)
  end
end
