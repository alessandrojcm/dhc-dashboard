defmodule Dhc.InventoryTest do
  @moduledoc """
  Domain-level tests for `Dhc.Inventory` (Equipment Category slice — ALE-105).

  Covers the context behavior that backs the `DhcWeb.InventoryCategoriesController`
  end-to-end contract tests: list/show with item-count aggregation, create/update
  uniqueness and validation, and the delete guard. The DB-shaped contract
  (status codes, camelCase rendering) is covered by
  `DhcWeb.InventoryCategoriesControllerTest`.
  """

  use Dhc.DataCase, async: true

  alias Dhc.Inventory
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Repo

  describe "list_categories/0" do
    test "returns categories ordered by name ascending" do
      insert_category(name: "Zzz")
      insert_category(name: "Aaa")
      insert_category(name: "Mmm")

      names =
        Inventory.list_categories()
        |> Enum.map(& &1.name)

      assert names == Enum.sort(names)
      # Inserted extremes bracket the seeded default categories.
      assert hd(names) == "Aaa"
      assert List.last(names) == "Zzz"
      assert "Mmm" in names
    end

    test "annotates every category with itemCount, defaulting to 0" do
      insert_category(name: "Empty")

      category =
        Inventory.list_categories()
        |> Enum.find(&(&1.name == "Empty"))

      assert category.item_count == 0
    end

    test "itemCount reflects the number of referencing inventory_items" do
      category = insert_category(name: "Counted")
      container_id = insert_container!()

      insert_item(container_id, category.id)

      category =
        Inventory.list_categories()
        |> Enum.find(&(&1.name == "Counted"))

      assert category.item_count == 1
    end
  end

  describe "get_category/1" do
    test "returns the category annotated with itemCount" do
      inserted = insert_category(name: "Lookup")

      assert {:ok, %EquipmentCategory{} = category} = Inventory.get_category(inserted.id)
      assert category.name == "Lookup"
      assert category.item_count == 0
    end

    test "returns {:error, :not_found} for a missing id" do
      assert {:error, :not_found} =
               Inventory.get_category(Ecto.UUID.generate())
    end

    test "counts referencing items" do
      inserted = insert_category(name: "Counted Show")
      container_id = insert_container!()
      insert_item(container_id, inserted.id)
      insert_item(container_id, inserted.id)

      assert {:ok, %EquipmentCategory{item_count: 2}} = Inventory.get_category(inserted.id)
    end
  end

  describe "create_category/1" do
    test "creates with camelCase payload keys" do
      assert {:ok, %EquipmentCategory{} = category} =
               Inventory.create_category(%{
                 "name" => "Inert Bucklers",
                 "description" => "Small shields",
                 "availableAttributes" => [
                   %{"name" => "brand", "type" => "text", "label" => "Brand", "required" => true}
                 ]
               })

      assert category.name == "Inert Bucklers"
      assert [attr] = category.available_attributes
      assert attr["name"] == "brand"
    end

    test "coerces an empty legacy {} column default to an empty list" do
      # Create without available_attributes; the column default is `'{}'::jsonb`
      # (an empty jsonb object), which JsonArray normalizes to `[]` on load.
      assert {:ok, %EquipmentCategory{} = category} =
               Inventory.create_category(%{"name" => "No Attrs"})

      reloaded = Repo.get!(EquipmentCategory, category.id)
      assert reloaded.available_attributes == []
    end

    test "returns {:error, changeset} when name is missing" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.create_category(%{"availableAttributes" => []})

      assert changeset.errors[:name]
    end

    test "returns {:error, :conflict, _} on a duplicate name" do
      insert_category(name: "Existing")

      assert {:error, :conflict, %Ecto.Changeset{}} =
               Inventory.create_category(%{"name" => "Existing"})
    end

    test "rejects non-array availableAttributes as a changeset error" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.create_category(%{
                 "name" => "Bad Attrs",
                 "availableAttributes" => "nope"
               })

      assert changeset.errors[:available_attributes]
    end

    test "rejects an attribute with an invalid type" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.create_category(%{
                 "name" => "Bad Type Attr",
                 "availableAttributes" => [%{"name" => "x", "type" => "frobnicate"}]
               })

      assert changeset.errors[:available_attributes]
    end
  end

  describe "update_category/2" do
    test "updates supplied fields and leaves the rest alone" do
      category = insert_category(name: "Old", description: "old desc")

      assert {:ok, %EquipmentCategory{} = updated} =
               Inventory.update_category(category.id, %{"description" => "new desc"})

      assert updated.name == "Old"
      assert updated.description == "new desc"
    end

    test "renames and reports itemCount after the update" do
      category = insert_category(name: "Rename Me")
      container_id = insert_container!()
      insert_item(container_id, category.id)

      assert {:ok, %EquipmentCategory{name: "Renamed", item_count: 1}} =
               Inventory.update_category(category.id, %{"name" => "Renamed"})
    end

    test "returns {:error, :not_found} for a missing id" do
      assert {:error, :not_found} =
               Inventory.update_category(Ecto.UUID.generate(), %{"name" => "X"})
    end

    test "returns {:error, :conflict, _} when renaming to an existing name" do
      insert_category(name: "Taken")
      category = insert_category(name: "Mine")

      assert {:error, :conflict, %Ecto.Changeset{}} =
               Inventory.update_category(category.id, %{"name" => "Taken"})
    end

    test "accepts rename to the same name (idempotent rename)" do
      category = insert_category(name: "Same")

      assert {:ok, %EquipmentCategory{name: "Same"}} =
               Inventory.update_category(category.id, %{"name" => "Same"})
    end
  end

  describe "delete_category/1" do
    test "deletes an unreferenced category" do
      category = insert_category(name: "Gone")

      assert {:ok, %EquipmentCategory{}} = Inventory.delete_category(category.id)
      refute Repo.get(EquipmentCategory, category.id)
    end

    test "returns {:error, :not_found} for a missing id" do
      assert {:error, :not_found} = Inventory.delete_category(Ecto.UUID.generate())
    end

    test "returns {:error, :still_referenced} when items reference it" do
      category = insert_category(name: "Referenced")
      container_id = insert_container!()
      insert_item(container_id, category.id)

      assert {:error, :still_referenced} = Inventory.delete_category(category.id)
      assert Repo.get(EquipmentCategory, category.id)
    end

    test "deletes once the referencing item is gone" do
      category = insert_category(name: "Now Free")
      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)

      assert {:error, :still_referenced} = Inventory.delete_category(category.id)

      Repo.query!("DELETE FROM inventory_items WHERE id = $1", [Ecto.UUID.dump!(item_id)])

      assert {:ok, %EquipmentCategory{}} = Inventory.delete_category(category.id)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defdelegate insert_category(attrs), to: Dhc.InventoryFixtures
  defdelegate insert_container!, to: Dhc.InventoryFixtures
  defdelegate insert_item(container_id, category_id), to: Dhc.InventoryFixtures
end
