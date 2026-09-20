defmodule Dhc.Inventory.LegacyInventoryTriggerCleanupTest do
  @moduledoc """
  Regression for DHC-API-1X.

  Production retained three Supabase-era triggers after ALE-289 dropped the
  columns and table their functions used. The from-scratch Ecto harness never
  had those objects, so this test installs the production-shaped drift before
  running the forward cleanup migration.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Repo
  alias Dhc.Repo.Migrations.Ale289RemoveLegacyInventoryTriggers, as: CleanupMigration

  @migration_version 20_260_919_185_939

  test "the cleanup removes legacy triggers and restores category and item writes" do
    actor_id = insert_principal!()
    {:ok, category} = Inventory.create_category(%{"name" => unique_name("Legacy category")})

    {:ok, container} =
      Inventory.create_container(%{"name" => unique_name("Legacy container")}, actor_id)

    install_legacy_inventory_objects!()

    error =
      assert_raise Postgrex.Error, fn ->
        Inventory.create_operator_item(
          %{"container_id" => container.id, "category_id" => category.id},
          actor_id
        )
      end

    assert %{postgres: %{code: :undefined_column, message: message}} = error
    assert message =~ ~s(column "attribute_schema" does not exist)

    run_cleanup_migration!()

    assert {:ok, _category} =
             Inventory.create_category(%{"name" => unique_name("Target category")})

    assert {:ok, item} =
             Inventory.create_operator_item(
               %{"container_id" => container.id, "category_id" => category.id},
               actor_id
             )

    assert item.slug =~ ~r/^item-\d{6,}$/
    assert legacy_inventory_objects() == []
  end

  defp run_cleanup_migration! do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @migration_version,
      CleanupMigration,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp install_legacy_inventory_objects! do
    Repo.query!("""
    CREATE FUNCTION generate_attribute_schema(attributes_array jsonb) RETURNS jsonb AS $$
    BEGIN
      RETURN '{}'::jsonb;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE FUNCTION update_category_schema() RETURNS trigger AS $$
    BEGIN
      NEW.attribute_schema := generate_attribute_schema(NEW.available_attributes);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE FUNCTION validate_item_attributes() RETURNS trigger AS $$
    DECLARE
      category_schema jsonb;
    BEGIN
      SELECT attribute_schema INTO category_schema
      FROM equipment_categories
      WHERE id = NEW.category_id;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE FUNCTION create_inventory_history() RETURNS trigger AS $$
    BEGIN
      PERFORM NEW.attributes, NEW.quantity, NEW.out_for_maintenance;
      INSERT INTO inventory_history (item_id) VALUES (NEW.id);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER category_schema_trigger
      BEFORE INSERT OR UPDATE ON equipment_categories
      FOR EACH ROW EXECUTE FUNCTION update_category_schema()
    """)

    Repo.query!("""
    CREATE TRIGGER validate_item_attributes_trigger
      BEFORE INSERT OR UPDATE ON inventory_items
      FOR EACH ROW EXECUTE FUNCTION validate_item_attributes()
    """)

    Repo.query!("""
    CREATE TRIGGER create_inventory_history_trigger
      AFTER INSERT OR UPDATE ON inventory_items
      FOR EACH ROW EXECUTE FUNCTION create_inventory_history()
    """)
  end

  defp legacy_inventory_objects do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT object_name
        FROM (
          SELECT tgname AS object_name
          FROM pg_trigger
          WHERE NOT tgisinternal

          UNION ALL

          SELECT proname AS object_name
          FROM pg_proc
          JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
          WHERE pg_namespace.nspname = current_schema()
        ) objects
        WHERE object_name = ANY($1::text[])
        ORDER BY object_name
        """,
        [
          [
            "category_schema_trigger",
            "create_inventory_history",
            "create_inventory_history_trigger",
            "generate_attribute_schema",
            "update_category_schema",
            "validate_item_attributes",
            "validate_item_attributes_trigger"
          ]
        ]
      )

    List.flatten(rows)
  end

  defp insert_principal! do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "inventory-cleanup-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp unique_name(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"
end
