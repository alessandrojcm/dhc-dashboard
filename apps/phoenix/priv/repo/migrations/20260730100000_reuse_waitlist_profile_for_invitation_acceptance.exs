defmodule Dhc.Repo.Migrations.ReuseWaitlistProfileForInvitationAcceptance do
  @moduledoc """
  ALE-176: enforce that each waitlist entry owns at most one UserProfile, and
  each UserProfile owns at most one guardian, so Invitation acceptance can
  reuse the existing waitlist UserProfile instead of creating a duplicate.

  ## Why

  `Dhc.Waitlist.create_entry/1` creates an inactive `user_profiles` row
  carrying the intake-captured fields (first/last/DOB/gender/pronouns/phone/
  social_media_consent/medical_conditions) plus an optional guardian row,
  keyed by `waitlist_id`. Pre-ALE-176, `accept/5` created a *second*
  `user_profiles` row keyed to the same `waitlist_id`, discarding the intake
  fields and orphaning the guardian.

  These two unique indexes make the one-to-one relationship explicit at the
  DB layer and let acceptance lock the existing row `FOR UPDATE` and reuse
  it, preserving the intake data and guardian linkage.

  ## Indexes

    * `user_profiles(waitlist_id)` partial unique `WHERE waitlist_id IS NOT
      NULL` — replaces the non-unique `user_profiles_waitlist_id_index`. The
      `WHERE` clause is required because `waitlist_id` is nullable (members
      created directly, never on the waitlist, have `waitlist_id = NULL`);
      Postgres treats multiple NULLs as distinct under a plain UNIQUE, but
      the partial form documents the invariant explicitly and keeps the
      index small.
    * `waitlist_guardians(profile_id)` unique — replaces the non-unique
      `waitlist_guardians_profile_id_index`.

  Both drops are guarded with `IF EXISTS` so re-running after a partial
  failure does not error.

  ## down/0

  Mechanically reversible: drops the two unique indexes and restores the
  two original non-unique indexes. No data is touched.
  """

  use Ecto.Migration

  @waitlist_id_index :user_profiles_waitlist_id_index
  @waitlist_id_unique :user_profiles_waitlist_id_unique
  @guardian_index :waitlist_guardians_profile_id_index
  @guardian_unique :waitlist_guardians_profile_id_unique

  def up do
    # Drop the non-unique indexes being replaced. IF EXISTS guards against a
    # partial failure leaving the migration half-applied.
    drop_if_exists(index(:user_profiles, [:waitlist_id], name: @waitlist_id_index))
    drop_if_exists(index(:waitlist_guardians, [:profile_id], name: @guardian_index))

    create(
      unique_index(:user_profiles, [:waitlist_id],
        name: @waitlist_id_unique,
        where: "waitlist_id IS NOT NULL"
      )
    )

    create(unique_index(:waitlist_guardians, [:profile_id], name: @guardian_unique))
  end

  def down do
    drop_if_exists(index(:user_profiles, [:waitlist_id], name: @waitlist_id_unique))
    drop_if_exists(index(:waitlist_guardians, [:profile_id], name: @guardian_unique))

    create(index(:user_profiles, [:waitlist_id], name: @waitlist_id_index))
    create(index(:waitlist_guardians, [:profile_id], name: @guardian_index))
  end
end
