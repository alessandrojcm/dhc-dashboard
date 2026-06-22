defmodule Dhc.Inventory do
  @moduledoc """
  Inventory read-model helpers used by Phoenix API controllers.

  This is the first Inventory read slice (issue ALE-94 / PRD #93): the
  overview counts endpoint. It establishes the minimal Ecto schema/query
  helper coverage needed for the overview path so later endpoint slices
  (activity, categories, containers, items — see PRD #93) can build on
  these schemas without re-deriving them.

  ## Vocabulary

  `inventory_items`, `equipment_categories`, `containers`, and
  `inventory_history` are **persistence** names only. The schemas in
  `Dhc.Inventory.*` map those tables, but every value returned from this
  module uses Inventory language: Container, Equipment Category, Inventory
  Item, and Inventory Activity. Controllers must not return the raw schemas;
  they return the maps built here.

  ## Authorization (RBAC) — read before reusing

  RBAC is enforced at the **controller** layer (mirroring the Waitlist,
  Members, and Workshops read migrations), not inside these helpers. The
  intended Phoenix RBAC for Inventory management reads mirrors the current
  dashboard Inventory gate:

      @inventory_management_roles ~w(quartermaster president admin)

  A member without an Inventory privilege must not read Inventory
  management data. This is stricter than the Workshops member collection
  (`authenticated_api`): the Inventory overview is a management-only read.

  ## Scope of this slice

  This slice covers the overview counts only (`GET /api/inventory/overview`).
  Inventory Activity (the `inventory_history` feed) is intentionally split
  into a separate endpoint (PRD #93, ALE-95) so the overview stays light.
  """

  import Ecto.Query

  alias Dhc.Inventory.{Container, EquipmentCategory, InventoryItem}
  alias Dhc.Repo

  # The canonical Phoenix RBAC for Inventory management reads. Mirrors the
  # current dashboard Inventory gate (`INVENTORY_ROLES` in
  # `src/lib/server/roles.ts`). Future controllers should reference this
  # list as the source of truth.
  @inventory_management_roles ~w(quartermaster president admin)

  @doc """
  Returns the canonical Inventory management roles.

  Exposed so the controller authorization plug and tests build against the
  same source of truth as this context, and so tests can assert the gate
  has not drifted.
  """
  @spec inventory_management_roles() :: [String.t()]
  def inventory_management_roles, do: @inventory_management_roles

  @doc """
  Returns the Inventory overview summary counts.

  The summary is a domain-shaped map with snake_case keys; the controller
  JSON renderer converts them to the camelCase contract
  (`summary.containerCount`, `summary.categoryCount`, `summary.itemCount`,
  `summary.maintenanceCount`).

  `maintenanceCount` is the number of Inventory Items currently out for
  maintenance (`out_for_maintenance = true`). It is a subset of
  `itemCount`, mirroring the existing SvelteKit read
  (`src/routes/dashboard/inventory/+page.server.ts`).

  Each count is a separate `SELECT count(*)` query rather than a single
  join/aggregation: the four counts are over different tables with no
  shared join key, and `maintenanceCount` is a filtered subset of
  `itemCount`. Running them in parallel via `Task.async_stream/3` keeps the
  overview endpoint fast without complicating the query layer.
  """
  @spec overview_counts() :: %{
          container_count: non_neg_integer(),
          category_count: non_neg_integer(),
          item_count: non_neg_integer(),
          maintenance_count: non_neg_integer()
        }
  def overview_counts do
    [
      fn -> Repo.one(from c in Container, select: count(c.id)) end,
      fn -> Repo.one(from c in EquipmentCategory, select: count(c.id)) end,
      fn -> Repo.one(from i in InventoryItem, select: count(i.id)) end,
      fn ->
        Repo.one(
          from i in InventoryItem,
            where: i.out_for_maintenance == true,
            select: count(i.id)
        )
      end
    ]
    |> Task.async_stream(
      fn fun -> fun.() end,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, value} -> value end)
    |> then(fn [containers, categories, items, maintenance] ->
      %{
        container_count: containers || 0,
        category_count: categories || 0,
        item_count: items || 0,
        maintenance_count: maintenance || 0
      }
    end)
  end
end