defmodule Dhc.InventoryFixtures do
  @moduledoc """
  Test helpers for the inventory domain: containers, categories, and bare
  item rows.

  Containers and categories go through the `Dhc.Inventory` context, so they
  satisfy the same constraints as production writes. `item_row!/2` inserts an
  `inventory_items` row directly, with no property values, for tests that
  only need an item to exist in a container (subtree walks, stored-value
  checks). Use `Dhc.Inventory.create_operator_item/2` when the test depends
  on validated values.

  All helpers run on the caller's connection, so they also work inside
  `Dhc.ConcurrencyHelpers.outside_sandbox/1` for committed fixtures.
  """

  alias Dhc.AuthFixtures
  alias Dhc.Inventory
  alias Dhc.Repo

  @doc """
  Creates a container. Options:

    * `:name` - default: auto-generated unique
    * `:parent_id` - parent container id (default: a root)
    * `:created_by` - Principal id (default: a fresh `principal_fixture/1`)
  """
  def container_fixture(opts \\ []) do
    attrs = %{"name" => Keyword.get_lazy(opts, :name, &unique_container_name/0)}

    attrs =
      case Keyword.get(opts, :parent_id) do
        nil -> attrs
        parent_id -> Map.put(attrs, "parentContainerId", parent_id)
      end

    created_by =
      Keyword.get_lazy(opts, :created_by, fn -> AuthFixtures.principal_fixture().id end)

    {:ok, container} = Inventory.create_container(attrs, created_by)
    container
  end

  @doc "Creates an equipment category, optionally with `:name`."
  def category_fixture(opts \\ []) do
    name =
      Keyword.get_lazy(opts, :name, fn ->
        "Category #{System.unique_integer([:positive])}"
      end)

    {:ok, category} = Inventory.create_category(%{"name" => name})
    category
  end

  @doc """
  Inserts a bare item row in `container_id` and returns its id. Without a
  `category_id`, a fresh category is created.
  """
  def item_row!(container_id, category_id \\ nil) do
    category_id = category_id || category_fixture().id
    item_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO inventory_items (id, container_id, category_id, slug, created_at, updated_at)
      VALUES ($1, $2, $3, $4, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(item_id),
        Ecto.UUID.dump!(container_id),
        Ecto.UUID.dump!(category_id),
        "item-#{System.unique_integer([:positive])}"
      ]
    )

    item_id
  end

  defp unique_container_name, do: "Container #{System.unique_integer([:positive])}"
end
