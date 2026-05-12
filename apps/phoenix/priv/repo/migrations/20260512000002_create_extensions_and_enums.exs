defmodule Dhc.Repo.Migrations.CreateExtensionsAndEnums do
  use Ecto.Migration

  def up do
    # Required extensions
    execute "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\""
    execute "CREATE EXTENSION IF NOT EXISTS pg_jsonschema WITH SCHEMA extensions"

    # ── Role types ──────────────────────────────────────────────
    execute """
    CREATE TYPE role_type AS ENUM (
      'admin',
      'president',
      'treasurer',
      'committee_coordinator',
      'sparring_coordinator',
      'workshop_coordinator',
      'beginners_coordinator',
      'quartermaster',
      'pr_manager',
      'volunteer_coordinator',
      'research_coordinator',
      'coach',
      'member'
    )
    """

    # ── Gender ──────────────────────────────────────────────────
    execute """
    CREATE TYPE gender AS ENUM (
      'man (cis)',
      'woman (cis)',
      'non-binary',
      'man (trans)',
      'woman (trans)',
      'other'
    )
    """

    # ── Social media consent ────────────────────────────────────
    execute "CREATE TYPE social_media_consent AS ENUM ('no', 'yes_recognizable', 'yes_unrecognizable')"

    # ── Preferred weapon ────────────────────────────────────────
    execute "CREATE TYPE preferred_weapon AS ENUM ('longsword', 'sword_and_buckler')"

    # ── Waitlist status ─────────────────────────────────────────
    execute """
    CREATE TYPE waitlist_status AS ENUM (
      'waiting',
      'invited',
      'paid',
      'deferred',
      'cancelled',
      'completed',
      'no_reply',
      'joined'
    )
    """

    # ── Club activity status ────────────────────────────────────
    execute """
    CREATE TYPE club_activity_status AS ENUM (
      'planned',
      'published',
      'finished',
      'cancelled'
    )
    """

    # ── Registration status ─────────────────────────────────────
    execute """
    CREATE TYPE registration_status AS ENUM (
      'pending',
      'confirmed',
      'cancelled',
      'refunded'
    )
    """

    # ── Refund status ───────────────────────────────────────────
    execute """
    CREATE TYPE refund_status AS ENUM (
      'pending',
      'processing',
      'completed',
      'failed',
      'cancelled'
    )
    """

    # ── Inventory action ────────────────────────────────────────
    execute """
    CREATE TYPE inventory_action AS ENUM (
      'created',
      'moved',
      'updated',
      'maintenance_out',
      'maintenance_in'
    )
    """

    # ── Invitation status ───────────────────────────────────────
    execute """
    CREATE TYPE invitation_status AS ENUM (
      'pending',
      'accepted',
      'expired',
      'revoked'
    )
    """

    # ── Setting type ────────────────────────────────────────────
    execute "CREATE TYPE setting_type AS ENUM ('text', 'boolean')"
  end

  def down do
    execute "DROP TYPE IF EXISTS setting_type"
    execute "DROP TYPE IF EXISTS invitation_status"
    execute "DROP TYPE IF EXISTS inventory_action"
    execute "DROP TYPE IF EXISTS refund_status"
    execute "DROP TYPE IF EXISTS registration_status"
    execute "DROP TYPE IF EXISTS club_activity_status"
    execute "DROP TYPE IF EXISTS waitlist_status"
    execute "DROP TYPE IF EXISTS preferred_weapon"
    execute "DROP TYPE IF EXISTS social_media_consent"
    execute "DROP TYPE IF EXISTS gender"
    execute "DROP TYPE IF EXISTS role_type"
    execute "DROP EXTENSION IF EXISTS pg_jsonschema"
    execute "DROP EXTENSION IF EXISTS \"uuid-ossp\""
  end
end
