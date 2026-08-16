defmodule Dhc.Repo.Migrations.DropAuthUsersFksAddInvitationAcceptanceColumns do
  use Ecto.Migration

  @moduledoc """
  ALE-162 — Move Invitation Acceptance to the Principal lifecycle (slice 3 of
  docs/auth-migration-specification.md, ADR 0010).

  ## Why this migration exists

  ALE-165 introduced Phoenix-owned `principals` (DHC-owned login identities)
  alongside the still-live Supabase Auth path. ADR 0010 fixes that the
  Authentication Principal is **born inside Invitation Acceptance**: issue
  time must mint only the invitation row (no `auth.users` row, no
  `user_profiles` row, no Stripe customer); acceptance atomically creates
  the Principal, `UserProfile`, `MemberProfile`, and `member` role in one
  transaction.

  That requires inserting `invitations`, `user_profiles`, `user_roles`, and
  `member_profiles` rows whose primary key / `*_user_id` column is a fresh
  Phoenix UUID with **no backing `auth.users` row**. Today those four
  columns all carry FK constraints to `auth.users.id`, so acceptance would
  violate them. This migration drops those FKs (and the
  `invitations.user_id` unique index, which would otherwise block re-issue
  with a fresh UUID after an invitation is expired).

  ## What this migration does NOT do

    * It does **not** rename `user_profiles.supabase_user_id` or
      `user_roles.user_id` to `principal_id`, and it does **not** add new
      FKs to `principals.id`. The rename + repoint is M2 / ALE-163 (slice 5
      of the spec), run under a write freeze. This migration is purely
      about the lifecycle change: dropping the `auth.users` dependency so
      acceptance can create the record set keyed by a Phoenix UUID.
    * It does **not** touch the unique index on
      `user_profiles.supabase_user_id` — that index stays, because the
      post-M1 invariant `principals.id == user_profiles.supabase_user_id`
      (one profile per principal) still needs a uniqueness guard.

  ## New columns on `invitations`

    * `date_of_birth` (`date`, nullable) — carried at issue time so
      `verify_credentials` can match email + DOB without a `user_profiles`
      row. The column is nullable because pre-ALE-162 invitations did not
      store it; production cutover deletes pending invitations (ADR 0010),
      so no backfill is needed.
    * `stripe_customer_id` (`text`, nullable) — lazily set by the pricing
      endpoint on first preview, reused by acceptance. Avoids creating a
      fresh customer in acceptance when the invitee already opened the
      pricing page. M2/ALE-166 will treat this column as a cutover
      migration input for already-accepted members (their customer id
      lives on `user_profiles.customer_id`); pending invitations at
      cutover are deleted.

  ## FK constraint names

  Ecto's `references/2` emits FK constraints with Postgres' default
  auto-name (`<table>_<column>_fkey`). The baseline migrations used
  `references(:users, prefix: "auth", ...)`, so the constraint names are:

    * `invitations.user_id`          -> `invitations_user_id_fkey`
    * `user_profiles.supabase_user_id` -> `user_profiles_supabase_user_id_fkey`
    * `member_profiles.id`           -> `member_profiles_id_fkey`
    * `user_roles.user_id`           -> `user_roles_user_id_fkey` (raw SQL table)

  Drop them by name so `down/0` can re-create them with the same name.
  """

  def up do
    # Drop the auth.users FK constraints. The columns stay; only the
    # constraint is removed. Renaming + repointing to principals.id is
    # ALE-163 / M2.
    execute "ALTER TABLE invitations DROP CONSTRAINT IF EXISTS invitations_user_id_fkey"

    execute "ALTER TABLE user_profiles DROP CONSTRAINT IF EXISTS user_profiles_supabase_user_id_fkey"

    execute "ALTER TABLE member_profiles DROP CONSTRAINT IF EXISTS member_profiles_id_fkey"

    execute "ALTER TABLE user_roles DROP CONSTRAINT IF EXISTS user_roles_user_id_fkey"

    # `invitations.user_id` had a unique index (baseline
    # 20260512000009_create_invitations.exs). Under the new lifecycle,
    # re-issuing an invitation for the same contact mints a fresh Phoenix
    # UUID in `user_id`, so the unique index would block re-issue after
    # expiry. Drop it; the unique index on `(email, status)` already
    # prevents two simultaneous pending invitations for the same email.
    drop_if_exists unique_index(:invitations, [:user_id])

    alter table(:invitations) do
      # ALE-162: the bulk-invite flow used to create the `user_profiles` row
      # at issue time, carrying first/last name, phone, and DOB. Under the
      # new lifecycle the UserProfile is created at acceptance, so the
      # invitation row must carry these fields between issue and acceptance.
      # All nullable: pre-ALE-162 rows lack them, and production cutover
      # deletes pending invitations (ADR 0010), so no backfill is needed.
      add :first_name, :text
      add :last_name, :text
      add :phone_number, :text
      add :date_of_birth, :date
      add :stripe_customer_id, :text
    end
  end

  def down do
    alter table(:invitations) do
      remove :stripe_customer_id
      remove :date_of_birth
      remove :phone_number
      remove :last_name
      remove :first_name
    end

    # Recreate the unique index on invitations.user_id.
    create unique_index(:invitations, [:user_id])

    # Recreate the auth.users FK constraints.
    execute """
    ALTER TABLE invitations
      ADD CONSTRAINT invitations_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE NOTHING
    """

    execute """
    ALTER TABLE user_profiles
      ADD CONSTRAINT user_profiles_supabase_user_id_fkey
      FOREIGN KEY (supabase_user_id) REFERENCES auth.users(id) ON DELETE NOTHING
    """

    execute """
    ALTER TABLE member_profiles
      ADD CONSTRAINT member_profiles_id_fkey
      FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE NOTHING
    """

    execute """
    ALTER TABLE user_roles
      ADD CONSTRAINT user_roles_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
    """
  end
end
