defmodule Dhc.Inventory do
  @moduledoc """
  Public Inventory capability context.

  This module is the stable Phoenix context boundary used by controllers and
  other callers. Implementation is split by inventory slice under
  `Dhc.Inventory.*` so category, container, item, and history behavior can stay
  navigable without changing the public API.
  """

  alias Dhc.Inventory.Categories
  alias Dhc.Inventory.Containers
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.InventoryHistory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemHistory
  alias Dhc.Inventory.Items

  @type category :: EquipmentCategory.t()
  @type container :: Containers.container()
  @type item :: Item.t()
  @type history :: InventoryHistory.t()

  defdelegate list_categories(), to: Categories
  defdelegate get_category(id), to: Categories
  defdelegate create_category(attrs), to: Categories
  defdelegate update_category(category_or_id, attrs), to: Categories
  defdelegate delete_category(category_or_id), to: Categories

  defdelegate list_containers(), to: Containers
  defdelegate get_container(id), to: Containers
  defdelegate create_container(attrs, actor_id), to: Containers
  defdelegate update_container(id, attrs), to: Containers
  defdelegate delete_container(id), to: Containers

  defdelegate list_items(opts \\ %{}), to: Items
  defdelegate get_item(id), to: Items
  defdelegate create_item(attrs, actor_id), to: Items
  defdelegate update_item(id, attrs, actor_id), to: Items
  defdelegate delete_item(id), to: Items
  defdelegate move_item(id, attrs, actor_id), to: Items
  defdelegate set_item_maintenance(id, attrs, actor_id), to: Items

  defdelegate list_item_history(id, opts \\ %{}), to: ItemHistory
  defdelegate list_history(opts \\ %{}), to: ItemHistory
end
