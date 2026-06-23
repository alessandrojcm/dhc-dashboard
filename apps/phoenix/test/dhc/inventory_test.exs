defmodule Dhc.InventoryTest do
  @moduledoc """
  Context-level read-model tests for `Dhc.Inventory` (PRD #93).

  Covers the read-model behavior for the Inventory read slices: the
  canonical Inventory management roles, the overview counts (ALE-94), the
  Inventory Item filter options (ALE-98), the Equipment Category list
  with item counts (ALE-96), the Container list (ALE-97), and the
  Inventory Item list (ALE-99). Controller-layer authorization is verified
  by `DhcWeb.InventoryControllerTest`; these tests assert external
  read-model behavior (shape, counts, ordering, role list) — not internal
  query mechanics.
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

  # ── Inventory Item list (ALE-99) ──────────────────────────────────────

  describe "list_items/1" do
    # Clear all inventory rows so assertions are deterministic.
    setup do
      Repo.delete_all(Dhc.Inventory.InventoryItem)
      Repo.delete_all(Dhc.Inventory.Container)
      Repo.delete_all(Dhc.Inventory.EquipmentCategory)
      :ok
    end

    test "returns an empty item list with zero total count when nothing is seeded" do
      assert {:ok, result} = Inventory.list_items(%{})

      assert result.items == []
      assert result.total_count == 0
      assert result.limit == 10
      assert result.next_cursor == nil
      assert result.previous_cursor == nil
    end

    test "returns items ordered by createdAt desc, id desc (newest first)" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      older =
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          created_at: ~U[2026-01-01 00:00:00Z]
        )

      newer =
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          created_at: ~U[2026-01-02 00:00:00Z]
        )

      {:ok, result} = Inventory.list_items(%{})

      assert Enum.map(result.items, & &1.id) == [newer.id, older.id]
    end

    test "selects only the contract fields, not timestamps or auth-user refs" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        attributes: %{"name" => "Mask A"}
      )

      {:ok, result} = Inventory.list_items(%{})

      [item] = result.items

      # Snake_case here; the renderer camelCases. `category`/`container` are
      # the nested `{id, name}` maps (built in SQL via json_build_object).
      assert Map.keys(item) |> Enum.sort() == [
               :attributes,
               :category,
               :container,
               :id,
               :maintenance_status,
               :quantity
             ]

      refute Map.has_key?(item, :inserted_at)
      refute Map.has_key?(item, :created_at)
      refute Map.has_key?(item, :updated_at)
      refute Map.has_key?(item, :created_by)
      refute Map.has_key?(item, :updated_by)
      refute Map.has_key?(item, :out_for_maintenance)
    end

    test "maintenance_status is the domain term (available / inMaintenance)" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      available =
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          out_for_maintenance: false
        )

      in_maintenance =
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          out_for_maintenance: true
        )

      {:ok, result} = Inventory.list_items(%{})

      by_id = Map.new(result.items, &{&1.id, &1.maintenance_status})

      assert by_id[available.id] == "available"
      assert by_id[in_maintenance.id] == "inMaintenance"
    end

    test "category and container are the nested {id, name} objects" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        attributes: %{"name" => "Mask A"}
      )

      {:ok, result} = Inventory.list_items(%{})

      [item] = result.items

      assert item.category == %{"id" => category.id, "name" => "Masks"}
      assert item.container == %{"id" => container.id, "name" => "Locker A"}
    end

    test "total_count counts every item matching the current filters" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      for _ <- 1..3 do
        InventoryFixtures.item_fixture(container_id: container.id, category_id: category.id)
      end

      {:ok, result} = Inventory.list_items(%{})

      assert result.total_count == 3
      # Default limit is 10, so all three are on the first page.
      assert length(result.items) == 3
    end

    test "paginates forward via cursor and stops with a null next_cursor" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      items =
        for index <- 1..15 do
          InventoryFixtures.item_fixture(
            container_id: container.id,
            category_id: category.id,
            created_at: DateTime.add(~U[2026-01-01 00:00:00Z], index, :second)
          )
        end

      {:ok, first_page} = Inventory.list_items(%{"limit" => "10"})

      assert length(first_page.items) == 10
      assert first_page.total_count == 15
      assert is_binary(first_page.next_cursor)
      # Forward pagination from page 1: no previous page.
      assert first_page.previous_cursor == nil

      # The first page is the 10 newest items.
      expected_first_ids =
        items
        |> Enum.sort_by(&{&1.created_at, &1.id}, :desc)
        |> Enum.take(10)
        |> Enum.map(& &1.id)

      assert Enum.map(first_page.items, & &1.id) == expected_first_ids

      {:ok, second_page} =
        Inventory.list_items(%{"limit" => "10", "cursor" => first_page.next_cursor})

      assert length(second_page.items) == 5
      assert second_page.total_count == 15
      assert second_page.next_cursor == nil
      # Paginating forward from page 2: a previous page exists.
      assert is_binary(second_page.previous_cursor)

      all_ids = Enum.map(first_page.items, & &1.id) ++ Enum.map(second_page.items, & &1.id)
      assert length(all_ids) == 15
      assert Enum.uniq(all_ids) == all_ids
    end

    test "paginates backward via previous_cursor" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      for index <- 1..15 do
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], index, :second)
        )
      end

      {:ok, first_page} = Inventory.list_items(%{"limit" => "10"})

      {:ok, second_page} =
        Inventory.list_items(%{"limit" => "10", "cursor" => first_page.next_cursor})

      # second_page.previous_cursor points at the page before the first item
      # of the second page. Paginating backwards from there returns the
      # first page in desc order.
      {:ok, back_page} =
        Inventory.list_items(%{"limit" => "10", "cursor" => second_page.previous_cursor})

      assert Enum.map(back_page.items, & &1.id) == Enum.map(first_page.items, & &1.id)
    end

    test "searches across item attributes.name, category name, and container name" do
      masks = InventoryFixtures.category_fixture(name: "Masks")
      gloves = InventoryFixtures.category_fixture(name: "Gloves")
      locker_a = InventoryFixtures.container_fixture(name: "Locker A")
      locker_b = InventoryFixtures.container_fixture(name: "Locker B")

      # attributes.name match
      InventoryFixtures.item_fixture(
        container_id: locker_a.id,
        category_id: masks.id,
        attributes: %{"name" => "Longsword Premium"}
      )

      # category name match
      InventoryFixtures.item_fixture(
        container_id: locker_a.id,
        category_id: gloves.id,
        attributes: %{"name" => "Item X"}
      )

      # container name match — both Locker B items match "locker b".
      InventoryFixtures.item_fixture(
        container_id: locker_b.id,
        category_id: masks.id,
        attributes: %{"name" => "Item Y"}
      )

      InventoryFixtures.item_fixture(
        container_id: locker_b.id,
        category_id: masks.id,
        attributes: %{"name" => "Item W"}
      )

      # no match — in Locker A, generic name, category Masks.
      InventoryFixtures.item_fixture(
        container_id: locker_a.id,
        category_id: masks.id,
        attributes: %{"name" => "Item Z"}
      )

      {:ok, result} = Inventory.list_items(%{"q" => "sword"})
      assert Enum.map(result.items, & &1.attributes["name"]) == ["Longsword Premium"]

      {:ok, result} = Inventory.list_items(%{"q" => "gloves"})
      assert Enum.map(result.items, & &1.attributes["name"]) == ["Item X"]

      {:ok, result} = Inventory.list_items(%{"q" => "locker b"})

      assert Enum.map(result.items, & &1.attributes["name"]) |> Enum.sort() ==
               ["Item W", "Item Y"]

      # total_count reflects the filtered set, not the full set.
      assert result.total_count == 2
    end

    test "filters by categoryId" do
      masks = InventoryFixtures.category_fixture(name: "Masks")
      gloves = InventoryFixtures.category_fixture(name: "Gloves")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      InventoryFixtures.item_fixture(container_id: container.id, category_id: masks.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: masks.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: gloves.id)

      {:ok, result} = Inventory.list_items(%{"categoryId" => masks.id})

      assert length(result.items) == 2
      assert result.total_count == 2
      assert Enum.all?(result.items, &(&1.category["id"] == masks.id))
    end

    test "filters by containerId" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      locker_a = InventoryFixtures.container_fixture(name: "Locker A")
      locker_b = InventoryFixtures.container_fixture(name: "Locker B")

      InventoryFixtures.item_fixture(container_id: locker_a.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: locker_a.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: locker_b.id, category_id: category.id)

      {:ok, result} = Inventory.list_items(%{"containerId" => locker_a.id})

      assert length(result.items) == 2
      assert result.total_count == 2
      assert Enum.all?(result.items, &(&1.container["id"] == locker_a.id))
    end

    test "filters by maintenanceStatus=inMaintenance" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: false
      )

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: true
      )

      {:ok, result} = Inventory.list_items(%{"maintenanceStatus" => "inMaintenance"})

      assert length(result.items) == 1
      assert result.total_count == 1
      assert hd(result.items).maintenance_status == "inMaintenance"
    end

    test "filters by maintenanceStatus=available" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: false
      )

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: true
      )

      {:ok, result} = Inventory.list_items(%{"maintenanceStatus" => "available"})

      assert length(result.items) == 1
      assert result.total_count == 1
      assert hd(result.items).maintenance_status == "available"
    end

    test "maintenanceStatus=all returns every item regardless of maintenance state" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: false
      )

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: true
      )

      {:ok, result} = Inventory.list_items(%{"maintenanceStatus" => "all"})

      assert length(result.items) == 2
      assert result.total_count == 2
    end

    test "returns {:error, :invalid_limit} for a limit outside the allowed set" do
      assert {:error, :invalid_limit} = Inventory.list_items(%{"limit" => "7"})
    end

    test "returns {:error, :bad_category_id} for a non-uuid categoryId" do
      assert {:error, :bad_category_id} = Inventory.list_items(%{"categoryId" => "nope"})
    end

    test "returns {:error, :bad_container_id} for a non-uuid containerId" do
      assert {:error, :bad_container_id} = Inventory.list_items(%{"containerId" => "nope"})
    end

    test "returns {:error, :invalid_maintenance_status} for an unknown maintenanceStatus" do
      assert {:error, :invalid_maintenance_status} =
               Inventory.list_items(%{"maintenanceStatus" => "broken"})
    end

    test "returns {:error, :bad_cursor} for an undecodable cursor" do
      assert {:error, :bad_cursor} = Inventory.list_items(%{"cursor" => "not-a-cursor"})
    end

    test "returns {:error, :bad_cursor} when the cursor was minted with a different limit" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      for index <- 1..15 do
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], index, :second)
        )
      end

      {:ok, first_page} = Inventory.list_items(%{"limit" => "10"})

      assert {:error, :bad_cursor} =
               Inventory.list_items(%{"limit" => "25", "cursor" => first_page.next_cursor})
    end

    test "returns {:error, :bad_cursor} when the cursor was minted with a different filter" do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      # Seed enough items to produce a non-nil next_cursor under limit=10.
      for index <- 1..12 do
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], index, :second)
        )
      end

      {:ok, first_page} = Inventory.list_items(%{"limit" => "10"})

      # Reuse the cursor with a maintenanceStatus filter — must be rejected.
      assert {:error, :bad_cursor} =
               Inventory.list_items(%{
                 "limit" => "10",
                 "maintenanceStatus" => "inMaintenance",
                 "cursor" => first_page.next_cursor
               })
    end
  end
end
