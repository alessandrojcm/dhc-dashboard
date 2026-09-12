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

  import Ecto.Query

  alias Dhc.Auth.Principal
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
    test "creates with name and description" do
      assert {:ok, %EquipmentCategory{} = category} =
               Inventory.create_category(%{
                 "name" => "Inert Bucklers",
                 "description" => "Small shields"
               })

      assert category.name == "Inert Bucklers"
      assert category.description == "Small shields"
    end

    test "ignores legacy attribute config keys" do
      # ALE-289 dropped the available_attributes / attribute_schema JSON
      # columns; typed definitions live behind Dhc.Inventory.Structure.
      # A stale caller still sending them must not fail or persist them.
      assert {:ok, %EquipmentCategory{} = category} =
               Inventory.create_category(%{
                 "name" => "No Attrs",
                 "availableAttributes" => [%{"name" => "brand", "type" => "text"}]
               })

      assert category.name == "No Attrs"
      refute Map.has_key?(Map.from_struct(category), :available_attributes)
    end

    test "returns {:error, changeset} when name is missing" do
      assert {:error, %Ecto.Changeset{} = changeset} = Inventory.create_category(%{})

      assert changeset.errors[:name]
    end

    test "returns {:error, :conflict, _} on a duplicate name" do
      insert_category(name: "Existing")

      assert {:error, :conflict, %Ecto.Changeset{}} =
               Inventory.create_category(%{"name" => "Existing"})
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

  defp insert_category(attrs) do
    attrs = Enum.into(attrs, %{})

    {:ok, category} =
      %EquipmentCategory{}
      |> Ecto.Changeset.cast(attrs, [:name, :description])
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    category
  end

  defp insert_container! do
    user_id = Ecto.UUID.generate()

    %Principal{id: user_id}
    |> Principal.email_changeset(%{
      email: "inv-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()

    container_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        "INSERT INTO containers (id, name, created_by, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
        [Ecto.UUID.dump!(container_id), "Test Container", Ecto.UUID.dump!(user_id)]
      )

    container_id
  end

  defp insert_item(container_id, category_id) do
    item_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        """
        INSERT INTO inventory_items
          (id, container_id, category_id, slug, created_at, updated_at)
        VALUES ($1, $2, $3, $4, NOW(), NOW())
        """,
        # All three are uuid columns — Postgrex requires 16-byte binaries, not
        # string UUIDs, for raw SQL parameters.
        [
          Ecto.UUID.dump!(item_id),
          Ecto.UUID.dump!(container_id),
          Ecto.UUID.dump!(category_id),
          "test-#{System.unique_integer([:positive])}"
        ]
      )

    {:ok, item_id}
  end
end
