defmodule Dhc.Repo.Migrations.UseCitextForGuestEmails do
  use Ecto.Migration

  def up do
    execute """
    DO $$
    DECLARE waitlist_collisions bigint;
    DECLARE external_user_collisions bigint;
    BEGIN
      SELECT count(*) INTO waitlist_collisions
        FROM (
          SELECT lower(email)
            FROM waitlist
           GROUP BY lower(email)
          HAVING count(*) > 1
        ) duplicates;

      SELECT count(*) INTO external_user_collisions
        FROM (
          SELECT lower(email)
            FROM external_users
           GROUP BY lower(email)
          HAVING count(*) > 1
        ) duplicates;

      IF waitlist_collisions > 0 OR external_user_collisions > 0 THEN
        RAISE EXCEPTION
          'Case-insensitive email collisions found (waitlist groups: %, external_users groups: %); reconcile them before retrying',
          waitlist_collisions, external_user_collisions
          USING ERRCODE = 'unique_violation';
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """

    # ALE-178 owns the invitations.email citext cast.
    execute "ALTER TABLE waitlist ALTER COLUMN email TYPE citext USING email::citext"

    execute "ALTER TABLE external_users ALTER COLUMN email TYPE citext USING email::citext"
  end

  def down do
    execute "ALTER TABLE external_users ALTER COLUMN email TYPE text USING email::text"

    execute "ALTER TABLE waitlist ALTER COLUMN email TYPE text USING email::text"
  end
end
