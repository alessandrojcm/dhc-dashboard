defmodule Dhc.InventoryTest do
  @moduledoc """
  Context-level read-model tests for `Dhc.Inventory` (PRD #93).

  Covers the read-model behavior for the Inventory read slices: the
  canonical Inventory management roles, the overview counts (ALE-94), the
  Inventory Item filter options (ALE-98), and the Equipment Category list
  with item counts (ALE-96). Controller-layer authorization is verified by
  `DhcWeb.InventoryControllerTest`; these tests assert external read-model
  behavior (shape, counts, ordering, role list) — not internal query
  mechanics.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Inventory
  alias Dhc.InventoryFixtures
  alias Dhc.Repo

  # ── RBAC / vocabulary ─────────────────────────────────────────────────

  describe "inventory_management_roles/0" do
    test "includes quartermaster, president, and admin" do
      roles = Inventory.inventory_management_roles()

      assert "quartermaster" in roles
      assert "president" in roles
      assert "admin" in roles
    end

    test "mirrors the existing dashboard Inventory gate (no broad committee roles)" do
      roles = Inventory.inventory_management_roles()

      # Members and unrelated committee roles must not read Inventory
      # management data. This mirrors `INVENTORY_ROLES` in
      # `src/lib/server/roles.ts` (the existing dashboard gate), which is
      # stricter than the Waitlist/Members/Workshops read RBAC.
      refute "member" in roles
      refute "committee_coordinator" in roles
      refute "workshop_coordinator" in roles
      refute "beginners_coordinator" in roles
      refute "coach" in roles
      refute "treasurer" in roles
    end
  end

  # ── Overview counts ──────────────────────────────────────────────────

  describe "overview_counts/0" do
    # The baseline migration seeds 7 default equipment categories; clear them
    # so count assertions are deterministic.
    setup do
      Repo.delete_all(Dhc.Inventory.EquipmentCategory)
      :ok
    end

    test "returns zero counts when the inventory is empty" do
      assert Inventory.overview_counts() == %{
               container_count: 0,
               category_count: 0,
               item_count: 0,
               maintenance_count: 0
             }
    end

    test "counts Containers, Equipment Categories, and Inventory Items separately" do
      InventoryFixtures.category_fixture()
      InventoryFixtures.category_fixture()
      InventoryFixtures.container_fixture()
      InventoryFixtures.container_fixture()
      InventoryFixtures.container_fixture()

      assert Inventory.overview_counts() == %{
               container_count: 3,
               category_count: 2,
               item_count: 0,
               maintenance_count: 0
             }
    end

    test "maintenance_count is the subset of items with out_for_maintenance = true" do
      category = InventoryFixtures.category_fixture()
      container = InventoryFixtures.container_fixture()

      # Two available, one in maintenance.
      InventoryFixtures.item_fixture(container_id: container.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: category.id)

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: true
      )

      assert Inventory.overview_counts() == %{
               container_count: 1,
               category_count: 1,
               item_count: 3,
               maintenance_count: 1
             }
    end

    test "returns the counts as snake_case keys (the renderer camelCases)" do
      InventoryFixtures.container_fixture()

      counts = Inventory.overview_counts()

      # Context returns snake_case; the JSON renderer converts to camelCase.
      assert Map.has_key?(counts, :container_count)
      assert Map.has_key?(counts, :category_count)
      assert Map.has_key?(counts, :item_count)
      assert Map.has_key?(counts, :maintenance_count)

      refute Map.has_key?(counts, "containerCount")
      refute Map.has_key?(counts, "itemCount")
    end
  end

  # ── Item filter options (ALE-98) ─────────────────────────────────────

  describe "filter_options/0" do
    # The baseline migration seeds 7 default equipment categories; clear them
    # plus containers/items so assertions are deterministic.
    setup do
      Repo.delete_all(Dhc.Inventory.InventoryItem)
      Repo.delete_all(Dhc.Inventory.Container)
      Repo.delete_all(Dhc.Inventory.EquipmentCategory)
      :ok
    end

    test "returns empty category and container lists when nothing is seeded" do
      assert Inventory.filter_options() == %{categories: [], containers: []}
    end

    test "returns categories and containers ordered by name asc" do
      InventoryFixtures.category_fixture(name: "Zweihänder")
      InventoryFixtures.category_fixture(name: "Axes")
      InventoryFixtures.category_fixture(name: "Masks")

      parent = InventoryFixtures.container_fixture(name: "Storage Room")
      InventoryFixtures.container_fixture(name: "Shelf Z")
      InventoryFixtures.container_fixture(name: "Shelf A")
      InventoryFixtures.container_fixture(name: "Shelf M", parent_container_id: parent.id)

      %{categories: categories, containers: containers} = Inventory.filter_options()

      assert Enum.map(categories, & &1.name) == ["Axes", "Masks", "Zweihänder"]

      assert Enum.map(containers, & &1.name) == [
               "Shelf A",
               "Shelf M",
               "Shelf Z",
               "Storage Room"
             ]
    end

    test "selects only the dropdown fields, not timestamps or auth-user refs" do
      InventoryFixtures.category_fixture(
        name: "Masks",
        available_attributes: [%{"name" => "brand", "type" => "text"}]
      )

      InventoryFixtures.container_fixture(name: "Locker A")

      %{categories: [category], containers: [container]} = Inventory.filter_options()

      # Category fields mirror the camelCase contract (snake_case here; the
      # renderer camelCases).
      assert Map.keys(category) |> Enum.sort() == [
               :attribute_schema,
               :available_attributes,
               :description,
               :id,
               :name
             ]

      refute Map.has_key?(category, :inserted_at)
      refute Map.has_key?(category, :created_at)
      refute Map.has_key?(category, :updated_at)

      # Container fields — no `created_by` auth-user ref, no timestamps.
      assert Map.keys(container) |> Enum.sort() ==
               [:description, :id, :name, :parent_container_id]

      refute Map.has_key?(container, :created_by)
      refute Map.has_key?(container, :inserted_at)
      refute Map.has_key?(container, :created_at)
      refute Map.has_key?(container, :updated_at)
    end

    test "preserves available_attributes as the jsonb array shape" do
      InventoryFixtures.category_fixture(
        name: "Masks",
        available_attributes: [
          %{"name" => "brand", "type" => "text", "required" => true, "label" => "Brand"}
        ]
      )

      %{categories: [category]} = Inventory.filter_options()

      assert category.available_attributes == [
               %{"name" => "brand", "type" => "text", "required" => true, "label" => "Brand"}
             ]
    end

    test "container parent_container_id is nil for top-level containers" do
      InventoryFixtures.container_fixture(name: "Locker A")

      %{containers: [container]} = Inventory.filter_options()

      assert container.parent_container_id == nil
    end

    test "container parent_container_id is populated for nested containers" do
      parent = InventoryFixtures.container_fixture(name: "Storage Room")
      InventoryFixtures.container_fixture(name: "Shelf", parent_container_id: parent.id)

      %{containers: [shelf, _storage_room]} = Inventory.filter_options()

      assert shelf.parent_container_id == parent.id
    end
  end

  # ── Equipment Category list (ALE-96) ──────────────────────────────────

  describe "list_categories/0" do
    # The baseline migration seeds 7 default equipment categories; clear them
    # plus containers/items so assertions are deterministic.
    setup do
      Repo.delete_all(Dhc.Inventory.InventoryItem)
      Repo.delete_all(Dhc.Inventory.Container)
      Repo.delete_all(Dhc.Inventory.EquipmentCategory)
      :ok
    end

    test "returns an empty category list when nothing is seeded" do
      assert Inventory.list_categories() == %{categories: []}
    end

    test "returns categories ordered by name asc" do
      InventoryFixtures.category_fixture(name: "Zweihänder")
      InventoryFixtures.category_fixture(name: "Axes")
      InventoryFixtures.category_fixture(name: "Masks")

      %{categories: categories} = Inventory.list_categories()

      assert Enum.map(categories, & &1.name) == ["Axes", "Masks", "Zweihänder"]
    end

    test "selects only the list fields, not timestamps or auth-user refs" do
      InventoryFixtures.category_fixture(
        name: "Masks",
        available_attributes: [%{"name" => "brand", "type" => "text"}]
      )

      %{categories: [category]} = Inventory.list_categories()

      # Category fields mirror the camelCase contract (snake_case here; the
      # renderer camelCases).
      assert Map.keys(category) |> Enum.sort() == [
               :available_attributes,
               :description,
               :id,
               :item_count,
               :name
             ]

      refute Map.has_key?(category, :inserted_at)
      refute Map.has_key?(category, :created_at)
      refute Map.has_key?(category, :updated_at)
      refute Map.has_key?(category, :created_by)
    end

    test "item_count is zero for a category with no Inventory Items" do
      InventoryFixtures.category_fixture(name: "Masks")

      %{categories: [category]} = Inventory.list_categories()

      assert category.item_count == 0
    end

    test "item_count counts the Inventory Items in each category" do
      masks = InventoryFixtures.category_fixture(name: "Masks")
      gloves = InventoryFixtures.category_fixture(name: "Gloves")
      container = InventoryFixtures.container_fixture()

      # Three Masks items, one Gloves item.
      InventoryFixtures.item_fixture(container_id: container.id, category_id: masks.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: masks.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: masks.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: gloves.id)

      %{categories: categories} = Inventory.list_categories()

      by_name = Map.new(categories, &{&1.name, &1.item_count})

      assert by_name["Masks"] == 3
      assert by_name["Gloves"] == 1
    end

    test "preserves available_attributes as the jsonb array shape" do
      InventoryFixtures.category_fixture(
        name: "Masks",
        available_attributes: [
          %{"name" => "brand", "type" => "text", "required" => true, "label" => "Brand"}
        ]
      )

      %{categories: [category]} = Inventory.list_categories()

      assert category.available_attributes == [
               %{"name" => "brand", "type" => "text", "required" => true, "label" => "Brand"}
             ]
    end
  end

  # ── Container list (ALE-97) ───────────────────────────────────────────

  describe "list_containers/0" do
    # The baseline migration seeds no default containers, but clear all
    # inventory rows so assertions are deterministic.
    setup do
      Repo.delete_all(Dhc.Inventory.InventoryItem)
      Repo.delete_all(Dhc.Inventory.Container)
      Repo.delete_all(Dhc.Inventory.EquipmentCategory)
      :ok
    end

    test "returns an empty container list when nothing is seeded" do
      assert Inventory.list_containers() == %{containers: []}
    end

    test "returns containers ordered by name asc" do
      InventoryFixtures.container_fixture(name: "Locker Z")
      InventoryFixtures.container_fixture(name: "Locker A")
      InventoryFixtures.container_fixture(name: "Locker M")

      %{containers: containers} = Inventory.list_containers()

      assert Enum.map(containers, & &1.name) == ["Locker A", "Locker M", "Locker Z"]
    end

    test "selects only the list fields, not timestamps or auth-user refs" do
      InventoryFixtures.container_fixture(name: "Locker A")

      %{containers: [container]} = Inventory.list_containers()

      # Container fields mirror the camelCase contract (snake_case here; the
      # renderer camelCases).
      assert Map.keys(container) |> Enum.sort() == [
               :description,
               :id,
               :item_count,
               :name,
               :parent_container,
               :parent_container_id
             ]

      refute Map.has_key?(container, :created_by)
      refute Map.has_key?(container, :inserted_at)
      refute Map.has_key?(container, :created_at)
      refute Map.has_key?(container, :updated_at)
      refute Map.has_key?(container, :created_at)
    end

    test "item_count is zero for a container with no Inventory Items" do
      InventoryFixtures.container_fixture(name: "Locker A")

      %{containers: [container]} = Inventory.list_containers()

      assert container.item_count == 0
    end

    test "item_count counts the Inventory Items directly in each container" do
      locker_a = InventoryFixtures.container_fixture(name: "Locker A")
      locker_b = InventoryFixtures.container_fixture(name: "Locker B")
      category = InventoryFixtures.category_fixture()

      # Three items in Locker A, one item in Locker B.
      InventoryFixtures.item_fixture(container_id: locker_a.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: locker_a.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: locker_a.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: locker_b.id, category_id: category.id)

      %{containers: containers} = Inventory.list_containers()

      by_name = Map.new(containers, &{&1.name, &1.item_count})

      assert by_name["Locker A"] == 3
      assert by_name["Locker B"] == 1
    end

    test "parent_container_id is nil for top-level containers" do
      InventoryFixtures.container_fixture(name: "Locker A")

      %{containers: [container]} = Inventory.list_containers()

      assert container.parent_container_id == nil
    end

    test "parent_container_id is populated for nested containers" do
      storage_room = InventoryFixtures.container_fixture(name: "Storage Room")
      InventoryFixtures.container_fixture(name: "Shelf", parent_container_id: storage_room.id)

      %{containers: [shelf, _storage_room]} = Inventory.list_containers()

      assert shelf.parent_container_id == storage_room.id
    end

    test "parent_container is nil for top-level containers" do
      InventoryFixtures.container_fixture(name: "Locker A")

      %{containers: [container]} = Inventory.list_containers()

      assert container.parent_container == nil
    end

    test "parent_container is the nested {id, name} object for nested containers" do
      storage_room = InventoryFixtures.container_fixture(name: "Storage Room")
      InventoryFixtures.container_fixture(name: "Shelf", parent_container_id: storage_room.id)

      %{containers: [shelf, _storage_room]} = Inventory.list_containers()

      assert shelf.parent_container == %{"id" => storage_room.id, "name" => "Storage Room"}
    end
  end
end
