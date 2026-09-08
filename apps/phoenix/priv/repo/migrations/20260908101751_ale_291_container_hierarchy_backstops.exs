defmodule Dhc.Repo.Migrations.Ale291ContainerHierarchyBackstops do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE containers DROP CONSTRAINT containers_parent_container_id_fkey"

    execute """
    ALTER TABLE containers
      ADD CONSTRAINT containers_parent_container_id_fkey
      FOREIGN KEY (parent_container_id) REFERENCES containers(id) ON DELETE RESTRICT
    """

    create unique_index(:containers, ["lower(name)"],
             where: "parent_container_id IS NULL",
             name: :containers_root_name_unique
           )

    create unique_index(:containers, [:parent_container_id, "lower(name)"],
             where: "parent_container_id IS NOT NULL",
             name: :containers_sibling_name_unique
           )

    execute """
    CREATE FUNCTION containers_reject_parent_cycles() RETURNS trigger AS $$
    BEGIN
      IF NEW.parent_container_id IS NULL THEN
        RETURN NEW;
      END IF;

      IF EXISTS (
        WITH RECURSIVE ancestors AS (
          SELECT id, parent_container_id FROM containers WHERE id = NEW.parent_container_id
          UNION ALL
          SELECT parent.id, parent.parent_container_id
          FROM containers parent
          JOIN ancestors child ON child.parent_container_id = parent.id
        )
        SELECT 1 FROM ancestors WHERE id = NEW.id
      ) THEN
        RAISE EXCEPTION 'container parent would create a cycle'
          USING ERRCODE = '23514', CONSTRAINT = 'containers_parent_acyclic';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE CONSTRAINT TRIGGER containers_parent_acyclic
      AFTER INSERT OR UPDATE OF parent_container_id ON containers
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION containers_reject_parent_cycles()
    """
  end

  def down do
    execute "DROP TRIGGER containers_parent_acyclic ON containers"
    execute "DROP FUNCTION containers_reject_parent_cycles()"
    drop index(:containers, name: :containers_sibling_name_unique)
    drop index(:containers, name: :containers_root_name_unique)
    execute "ALTER TABLE containers DROP CONSTRAINT containers_parent_container_id_fkey"

    execute """
    ALTER TABLE containers
      ADD CONSTRAINT containers_parent_container_id_fkey
      FOREIGN KEY (parent_container_id) REFERENCES containers(id) ON DELETE CASCADE
    """
  end
end
