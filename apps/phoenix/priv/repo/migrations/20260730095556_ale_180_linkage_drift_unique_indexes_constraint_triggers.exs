defmodule Dhc.Repo.Migrations.Ale180LinkageDriftUniqueIndexesConstraintTriggers do
  @moduledoc """
  ALE-180: enforce the triangle invariant `member_profiles.id ==
  user_profiles.principal_id` at the DB layer.

  ## Why

  `member_profiles` is keyed by the Principal id (`member_profiles.id`), and
  `user_profiles.principal_id` records the owning Principal. The two are
  linked by `member_profiles.user_profile_id → user_profiles.id`. The
  intended invariant is the triangle:

      member_profiles.id == user_profiles.principal_id
        where member_profiles.user_profile_id == user_profiles.id

  Nothing enforced it. A `member_profiles` row could point (via
  `user_profile_id`) at a `user_profiles` row owned by a *different*
  Principal — linkage drift — silently corrupting the ownership graph.

  ## What this migration does

    1. Drops the non-unique `member_profiles.user_profile_id` index and adds
       a unique one. Each UserProfile is owned by at most one MemberProfile.
    2. Adds a partial `user_profiles(customer_id)` unique index
       (`WHERE customer_id IS NOT NULL AND customer_id <> ''`). Raises if
       production has duplicate non-blank customer ids — that is the correct
       abort, since it means the Stripe customer link is already ambiguous.
       `customer_id` is nullable (waitlist-only profiles and pre-Stripe
       members have NULL), so the partial form is required.
    3. Creates `verify_linkage_drift()`, a trigger function that raises only
       when a *linked pair exists and disagrees*: i.e. there is a
       `member_profiles` row whose `user_profile_id` points at a
       `user_profiles` row whose `principal_id` differs from the
       `member_profiles.id` (the Principal). Waitlist-only UserProfiles (no
       MemberProfile yet) are untouched because no linked pair exists.
    4. Attaches the function via three `CONSTRAINT TRIGGER`s:
         - INSERT on `member_profiles`
         - UPDATE of `member_profiles.user_profile_id`
         - UPDATE of `user_profiles.principal_id`

  The triggers raise with constraint name `linkage_drift_violation` so the
  application can distinguish the failure from a plain unique violation.

  ## down/0

  Mechanically reversible: drops the three triggers, the function, and the
  two indexes, and restores the original non-unique
  `member_profiles.user_profile_id` index. No data is touched. The
  `user_profiles(customer_id)` partial unique is not restored on rollback
  (it never existed pre-ALE-180); dropping it is the reversal.
  """

  use Ecto.Migration

  @member_profile_id_index :member_profiles_user_profile_id_index
  @member_profile_id_unique :member_profiles_user_profile_id_unique
  @customer_id_unique :user_profiles_customer_id_unique

  # Trigger / function names are fixed strings so up/0 and down/0 agree even
  # if the index names change.
  @function "verify_linkage_drift"
  @trigger_mp_insert "member_profiles_linkage_drift_insert"
  @trigger_mp_update "member_profiles_linkage_drift_update_user_profile_id"
  @trigger_up_update "user_profiles_linkage_drift_update_principal_id"

  def up do
    execute "LOCK TABLE member_profiles, user_profiles IN SHARE ROW EXCLUSIVE MODE"

    execute """
    DO $$
    DECLARE drifted_pairs bigint;
    BEGIN
      SELECT count(*) INTO drifted_pairs
        FROM member_profiles mp
        JOIN user_profiles up ON up.id = mp.user_profile_id
       WHERE up.principal_id IS DISTINCT FROM mp.id;

      IF drifted_pairs > 0 THEN
        RAISE EXCEPTION
          'ALE-180: % existing member/user profile pairs violate the linkage invariant; reconcile them before retrying',
          drifted_pairs
          USING ERRCODE = 'check_violation', CONSTRAINT = 'linkage_drift_violation';
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """

    # 1. member_profiles.user_profile_id: non-unique → unique.
    drop_if_exists(index(:member_profiles, [:user_profile_id], name: @member_profile_id_index))

    create(unique_index(:member_profiles, [:user_profile_id], name: @member_profile_id_unique))

    # 2. user_profiles.customer_id partial unique. CREATE UNIQUE INDEX raises
    # if production already has duplicate non-null customer ids — the correct
    # abort, because the Stripe customer link is ambiguous and must be
    # reconciled before this migration can land. Deliberately NOT guarded with
    # IF NOT EXISTS: a name collision would only mask a half-applied state, and
    # duplicate *values* raise regardless. Mirrors the non-idempotent
    # `create(unique_index(...))` style of the ALE-176 sibling migration.
    execute """
    CREATE UNIQUE INDEX #{@customer_id_unique}
      ON user_profiles (customer_id)
      WHERE customer_id IS NOT NULL AND customer_id <> ''
    """

    # 3. The drift-check function. Raises only when a linked pair exists and
    # disagrees. The function inspects the `NEW` row directly (no TG_ARGV;
    # the triggers invoke it with no arguments) and resolves the "other side"
    # of the triangle from `NEW`, depending on which table fired the trigger:
    #
    # The function resolves the "other side" of the triangle from the NEW
    # row, depending on which table fired the trigger:
    #
    #   * member_profiles (NEW has id=principal, user_profile_id):
    #       look up user_profiles.principal_id for NEW.user_profile_id and
    #       compare to NEW.id.
    #   * user_profiles (NEW has id=profile_id, principal_id):
    #       look up member_profiles.id linked by user_profile_id = NEW.id and
    #       compare to NEW.principal_id.
    #
    # Either lookup may return nothing (waitlist-only profile, or a
    # UserProfile with no MemberProfile yet) — in that case there is no linked
    # pair, so no drift, and the function returns the NEW row unchanged.
    execute """
    CREATE OR REPLACE FUNCTION #{@function}() RETURNS trigger AS $$
    DECLARE
      mp_id uuid;
      up_principal_id uuid;
    BEGIN
      IF TG_TABLE_NAME = 'member_profiles' THEN
        SELECT up.principal_id INTO up_principal_id
        FROM user_profiles up
        WHERE up.id = NEW.user_profile_id;

        IF NOT FOUND THEN
          RETURN NEW;
        END IF;

        IF up_principal_id IS DISTINCT FROM NEW.id THEN
          RAISE EXCEPTION 'linkage drift: member_profiles.id % does not match user_profiles.principal_id % for user_profile_id %',
            NEW.id, up_principal_id, NEW.user_profile_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'linkage_drift_violation';
        END IF;
      ELSE
        SELECT mp.id INTO mp_id
        FROM member_profiles mp
        WHERE mp.user_profile_id = NEW.id;

        IF mp_id IS NULL THEN
          RETURN NEW;
        END IF;

        IF mp_id IS DISTINCT FROM NEW.principal_id THEN
          RAISE EXCEPTION 'linkage drift: user_profiles.principal_id % does not match member_profiles.id % for user_profile_id %',
            NEW.principal_id, mp_id, NEW.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'linkage_drift_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    # 4. Constraint triggers. CONSTRAINT TRIGGER runs after the row is
    # written but within the statement transaction, so it can abort the
    # write. FOR EACH ROW fires per affected row.
    execute """
    CREATE CONSTRAINT TRIGGER #{@trigger_mp_insert}
      AFTER INSERT ON member_profiles
      FOR EACH ROW
      EXECUTE FUNCTION #{@function}()
    """

    execute """
    CREATE CONSTRAINT TRIGGER #{@trigger_mp_update}
      AFTER UPDATE OF user_profile_id ON member_profiles
      FOR EACH ROW
      WHEN (NEW.user_profile_id IS DISTINCT FROM OLD.user_profile_id)
      EXECUTE FUNCTION #{@function}()
    """

    execute """
    CREATE CONSTRAINT TRIGGER #{@trigger_up_update}
      AFTER UPDATE OF principal_id ON user_profiles
      FOR EACH ROW
      WHEN (NEW.principal_id IS DISTINCT FROM OLD.principal_id)
      EXECUTE FUNCTION #{@function}()
    """
  end

  def down do
    # `DROP TRIGGER IF EXISTS` handles both regular and constraint triggers;
    # `DROP CONSTRAINT TRIGGER` does not support IF EXISTS on this Postgres.
    execute "DROP TRIGGER IF EXISTS #{@trigger_up_update} ON user_profiles"
    execute "DROP TRIGGER IF EXISTS #{@trigger_mp_update} ON member_profiles"
    execute "DROP TRIGGER IF EXISTS #{@trigger_mp_insert} ON member_profiles"

    execute "DROP FUNCTION IF EXISTS #{@function}()"

    drop_if_exists(index(:user_profiles, [:customer_id], name: @customer_id_unique))

    drop_if_exists(index(:member_profiles, [:user_profile_id], name: @member_profile_id_unique))

    create(index(:member_profiles, [:user_profile_id], name: @member_profile_id_index))
  end
end
