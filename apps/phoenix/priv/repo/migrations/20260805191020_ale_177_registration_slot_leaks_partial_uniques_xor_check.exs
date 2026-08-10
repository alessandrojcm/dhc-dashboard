defmodule Dhc.Repo.Migrations.Ale177RegistrationSlotLeaksPartialUniquesXorCheck do
  @moduledoc """
  ALE-177: cancelled and refunded Registrations free their slot for
  re-registration, and the participant XOR invariant is enforced at the DB
  layer.

  ## Why

  The baseline `20260512000008_create_registrations_and_refunds.exs` created
  two *full* `UNIQUE(club_activity_id, member_user_id)` and
  `UNIQUE(club_activity_id, external_user_id)` indexes. Because they were
  not scoped to active statuses, a cancelled or refunded Registration
  permanently held its slot — a member who cancelled (or was refunded) and
  tried to re-register for the same Workshop hit a unique violation even
  though the historical row was a closed chapter. The fix is to scope the
  uniques to `status IN ('pending','confirmed')` so historical
  cancelled/refunded rows no longer collide with a fresh registration.

  The same baseline also left `member_user_id` and `external_user_id` both
  nullable with no DB-level enforcement that exactly one is set. The
  `Dhc.Workshops.Registration.fixture_changeset/2` references an
  `:exactly_one_participant` CHECK constraint that no migration had ever
  created — a moduledoc-claimed invariant with no DB backing. This
  migration adds that CHECK (`num_nonnulls(member_user_id, external_user_id)
  = 1`) so the XOR is enforced at the DB layer, not just in the changeset.

  ## What this migration does

    1. Drops the two full uniques:
         * `club_activity_registrations_club_activity_id_member_user_id_index`
         * `club_activity_registrations_club_activity_id_external_user_id_index`
    2. Adds two partial uniques scoped to active statuses:
         * `UNIQUE(club_activity_id, member_user_id) WHERE status IN
           ('pending','confirmed')`
         * `UNIQUE(club_activity_id, external_user_id) WHERE status IN
           ('pending','confirmed')`
       The `WHERE` uses the `registration_status` enum cast so the partial
       predicate matches the enum column type.
    3. Adds the `exactly_one_participant` CHECK
       (`num_nonnulls(member_user_id, external_user_id) = 1`)
       **idempotently** via a `pg_constraint` guard: the migration checks
       `pg_constraint` for an existing constraint of that name before
       `ALTER TABLE ADD CONSTRAINT`, so re-running on an already-migrated
       DB does not error on a duplicate-constraint violation.
    4. Adds the `(club_activity_id, created_at, id)` partial composite
       index scoped to `status IN ('pending','confirmed')` so the
       summary (`summary_query/0`) and calendar queries — which count and
       list registrations filtered to pending/confirmed — perform without a
       separate status index (ALE-185 later drops the redundant standalone
       `club_activity_registrations_status_index`).

  ## down/0

  Unsafe-after-write. A rollback after a fresh re-registration has been
  written (a row that collides under the old full unique) would fail or
  silently allow the duplicate the partial unique was introduced to
  prevent. Backup-restore is the only rollback. `down/0` raises to make
  this explicit rather than silently no-op.
  """

  use Ecto.Migration

  # The original baseline created these with Ecto's default name (which
  # Postgres silently truncates to 63 bytes — the default names are 64/65
  # bytes). `drop_if_exists` quotes the name and Postgres truncates both the
  # stored and queried identifiers to 63 bytes, so the match still succeeds.
  @old_member_unique :club_activity_registrations_club_activity_id_member_user_id_index
  @old_external_unique :club_activity_registrations_club_activity_id_external_user_id_index

  # New names kept under Postgres' 63-byte identifier limit so no truncation
  # surprises: the `_active` suffix denotes the `status IN
  # ('pending','confirmed')` partial predicate.
  @member_unique :club_activity_registrations_member_user_id_active_unique
  @external_unique :club_activity_registrations_external_user_id_active_unique
  @composite_index :club_activity_registrations_activity_created_at_id_index
  @xor_check :exactly_one_participant

  # The partial predicate, expressed against the `registration_status` enum
  # so the partial index matches the enum column type (a bare string
  # literal would not cast and the index would fail to apply). Both the
  # partial uniques and the composite index use the same predicate so the
  # summary/calendar queries (which filter `status in
  # @counted_registration_statuses` — pending/confirmed) hit one index each.
  @active_predicate "status IN ('pending'::registration_status, 'confirmed'::registration_status)"

  def up do
    execute """
    DO $$
    DECLARE invalid_participants bigint;
    BEGIN
      SELECT count(*) INTO invalid_participants
        FROM club_activity_registrations
       WHERE num_nonnulls(member_user_id, external_user_id) <> 1;

      IF invalid_participants > 0 THEN
        RAISE EXCEPTION
          'ALE-177: % registrations violate the exactly-one-participant invariant; reconcile them before retrying',
          invalid_participants
          USING ERRCODE = 'check_violation', CONSTRAINT = '#{@xor_check}';
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """

    # 1. Drop the two full uniques being replaced. `drop_if_exists` guards
    #    against a partial failure leaving the migration half-applied.
    drop_if_exists(
      unique_index(:club_activity_registrations, [:club_activity_id, :member_user_id],
        name: @old_member_unique
      )
    )

    drop_if_exists(
      unique_index(:club_activity_registrations, [:club_activity_id, :external_user_id],
        name: @old_external_unique
      )
    )

    # 2. Add the two partial uniques scoped to active statuses. The partial
    #    form lets a cancelled/refunded historical row coexist with a fresh
    #    pending/confirmed row for the same (participant, workshop).
    create(
      unique_index(:club_activity_registrations, [:club_activity_id, :member_user_id],
        name: @member_unique,
        where: @active_predicate
      )
    )

    create(
      unique_index(:club_activity_registrations, [:club_activity_id, :external_user_id],
        name: @external_unique,
        where: @active_predicate
      )
    )

    # 3. Add the `exactly_one_participant` XOR CHECK idempotently. The
    #    `pg_constraint` guard checks for an existing constraint of that
    #    name before ADD CONSTRAINT, so re-running on an already-migrated
    #    DB (e.g. after a partial failure that left the constraint in place)
    #    does not error on a duplicate-constraint violation.
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = '#{@xor_check}'
           AND conrelid = 'club_activity_registrations'::regclass
      ) THEN
        ALTER TABLE club_activity_registrations
          ADD CONSTRAINT #{@xor_check}
          CHECK (num_nonnulls(member_user_id, external_user_id) = 1);
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """

    # 4. Add the `(club_activity_id, created_at, id)` partial composite
    #    index scoped to active statuses so summary/calendar queries
    #    (filtered to pending/confirmed) perform.
    create(
      index(:club_activity_registrations, [:club_activity_id, :created_at, :id],
        name: @composite_index,
        where: @active_predicate
      )
    )
  end

  def down do
    # Unsafe-after-write. A rollback after a fresh re-registration has been
    # written would either fail (re-adding the full unique collides with the
    # historical + fresh rows the partial unique was introduced to allow) or
    # silently re-expose the slot leak. Backup-restore is the only rollback.
    # Raise rather than silently no-op so an operator does not mistake a
    # no-op for a real rollback.
    raise """
    ALE-177 down/0 is unsafe-after-write and not implemented.
    Re-adding the full uniques would collide with re-registration rows the
    partial uniques were introduced to allow, and dropping the XOR CHECK
    would re-expose the participant-invariant gap. Backup-restore is the
    only rollback. See ALE-187 runbook.
    """
  end
end
