defmodule Dhc.Repo.Migrations.ArchiveWorkshopsAndSnapshotAttendees do
  @moduledoc """
  ALE-181: Workshop soft-delete + attendee snapshot + financial-tail FK repoints.

  ## Why

  Workshop hard-delete cascaded `club_activity_registrations` and
  `club_activity_refunds`, destroying financial and audit history. A Workshop
  with any registration history must be retained; only Workshops with no
  registrations can be hard-deleted.

  Attendee identity was read by joining `club_activity_registrations` back to
  `user_profiles` / `external_users` at read time, so a member anonymizing
  their profile would corrupt event and payment history. Capturing an
  attendee snapshot (`display_name`, `email`) on the registration row at write
  time fixes the read to a stable point-in-time copy.

  ## What this migration does

    1. Adds `club_activities.archived_at` (nullable `timestamptz`). A non-null
       value marks a soft-deleted (archived) Workshop; `summary_query/0`
       filters `archived_at IS NULL` so archived Workshops drop out of
       summaries.
    2. Adds `club_activity_registrations.display_name` (`text`, ends `NOT NULL`)
       and `email` (`text`, stays nullable — member registrations do not
       capture an email at write time). Both are the attendee snapshot.
       Backfilled from live joins: members from `user_profiles` first/last
       name and `principals.email`; externals from `external_users`
       first/last name and `email`. A missing member profile resolves to the
       `'[unknown member]'` sentinel so the backfill never fails on a
       dangling `member_user_id`.
    3. Repoints the two financial-tail FKs to `ON DELETE RESTRICT` so
       financial and audit records are retained permanently:
         * `club_activity_registrations.club_activity_id → club_activities`
           (was `ON DELETE DELETE`).
         * `club_activity_refunds.registration_id → club_activity_registrations`
           (was `ON DELETE DELETE`).

       These RESTRICT FKs make the hard-delete path impossible for a
       Workshop that has registrations: `delete_workshop/1` now gates
       archive-vs-hard-delete on registrations-existence (the status gate is
       dropped).

  ## down/0

  Unsafe-after-write. Archives are one-way: a Workshop that has been
  archived and then had registrations written against it (the snapshot
  columns are now populated for those new rows) cannot be safely
  un-archived with the financial-tail FKs back to DELETE — the cascade
  would delete financial rows that the archive was meant to protect.
  Backup-restore is the only rollback. `down/0` raises to make this
  explicit rather than silently no-op.
  """

  use Ecto.Migration

  # Ecto default FK constraint names from
  # `20260512000008_create_registrations_and_refunds.exs`.
  @registrations_activity_fk :club_activity_registrations_club_activity_id_fkey
  @refunds_registration_fk :club_activity_refunds_registration_id_fkey

  @unknown_member "[unknown member]"

  def up do
    # 1. Soft-delete marker on Workshops. Nullable: a Workshop that has never
    #    been archived has `archived_at = NULL`. `summary_query/0` filters on
    #    this to exclude archived Workshops from summaries.
    alter table(:club_activities) do
      add :archived_at, :timestamptz
    end

    # 2. Attendee snapshot columns. Added nullable first so the backfill can
    #    populate every row before the NOT NULL is applied to `display_name`.
    alter table(:club_activity_registrations) do
      add :display_name, :text
      add :email, :text
    end

    # Backfill members: `display_name` from user_profiles first/last name,
    # `email` from principals.email (reached via user_profiles.principal_id =
    # member_user_id). A dangling member_user_id (no user_profiles row) falls
    # back to the sentinel so the backfill never aborts on drift; such rows
    # are pre-existing data issues surfaced by the snapshot rather than
    # hidden by it.
    execute """
    UPDATE club_activity_registrations r
       SET display_name = COALESCE(
            trim(COALESCE(up.first_name, '') || ' ' || COALESCE(up.last_name, '')),
            '#{@unknown_member}'
          ),
           email = p.email
      FROM user_profiles up
      JOIN principals p ON p.id = up.principal_id
     WHERE r.member_user_id IS NOT NULL
       AND up.principal_id = r.member_user_id
    """

    # Any member registration whose member_user_id did not resolve to a
    # user_profiles row gets the sentinel so the NOT NULL below can apply.
    execute """
    UPDATE club_activity_registrations
       SET display_name = '#{@unknown_member}'
     WHERE member_user_id IS NOT NULL
       AND display_name IS NULL
    """

    # Backfill externals: `display_name` from external_users first/last name,
    # `email` from external_users.email. A dangling external_user_id falls
    # back to the sentinel; the email stays NULL (we do not invent one).
    execute """
    UPDATE club_activity_registrations r
       SET display_name = COALESCE(
            trim(COALESCE(eu.first_name, '') || ' ' || COALESCE(eu.last_name, '')),
            '#{@unknown_member}'
          ),
           email = eu.email
      FROM external_users eu
     WHERE r.external_user_id IS NOT NULL
       AND eu.id = r.external_user_id
    """

    execute """
    UPDATE club_activity_registrations
       SET display_name = '#{@unknown_member}'
     WHERE external_user_id IS NOT NULL
       AND display_name IS NULL
    """

    # `display_name` is now populated for every row; enforce it. `email`
    # stays nullable — member registrations do not capture an email at write
    # time (the member's email lives on `principals.email`, not on the
    # registration), and a no-profile sentinel row has no email either.
    alter table(:club_activity_registrations) do
      modify :display_name, :text, null: false
    end

    # 3. Repoint the two financial-tail FKs to RESTRICT so financial and
    #    audit records are retained permanently. Drop the existing
    #    constraint and re-add it with the new on_delete action; the column
    #    itself is unchanged.
    execute """
    ALTER TABLE club_activity_registrations
      DROP CONSTRAINT #{@registrations_activity_fk},
      ADD CONSTRAINT #{@registrations_activity_fk}
        FOREIGN KEY (club_activity_id)
        REFERENCES club_activities(id)
        ON DELETE RESTRICT
    """

    execute """
    ALTER TABLE club_activity_refunds
      DROP CONSTRAINT #{@refunds_registration_fk},
      ADD CONSTRAINT #{@refunds_registration_fk}
        FOREIGN KEY (registration_id)
        REFERENCES club_activity_registrations(id)
        ON DELETE RESTRICT
    """
  end

  def down do
    # Unsafe-after-write. Archives are one-way: a Workshop that has been
    # archived and then had registrations written against it (the snapshot
    # columns are now populated for those new rows) cannot be safely
    # un-archived with the financial-tail FKs back to DELETE — the cascade
    # would delete financial rows that the archive was meant to protect.
    # Backup-restore is the only rollback. Raise rather than silently no-op
    # so an operator does not mistake a no-op for a real rollback.
    raise """
    Workshop archival down/0 is unsafe-after-write and not implemented.
    Archives and the snapshot backfill are one-way, and reverting the
    RESTRICT FKs back to DELETE would re-expose financial history to
    cascade deletion. Backup-restore is the only rollback.
    """
  end
end
