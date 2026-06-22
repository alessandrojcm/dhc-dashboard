defmodule Dhc.InventoryTest do
  @moduledoc """
  Context-level read-model tests for `Dhc.Inventory` (issue ALE-94 / PRD #93).

  Covers the read-model behavior needed by the overview endpoint slice:
  the canonical Inventory management roles, and the four overview counts
  (Containers, Equipment Categories, Inventory Items, and Items out for
  maintenance). Controller-layer authorization is verified by
  `DhcWeb.InventoryControllerTest`; these tests assert external read-model
  behavior (shape, counts, role list) — not internal query mechanics.
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

      refute Map.has_key?(counts, :containerCount)
      refute Map.has_key?(counts, :itemCount)
    end
  end
end