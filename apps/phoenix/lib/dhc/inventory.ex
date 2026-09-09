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
  alias Dhc.Inventory.OperatorItems
  alias Dhc.Inventory.Stats
  alias Dhc.Inventory.Structure

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
  defdelegate move_container(id, parent_container_id), to: Containers
  defdelegate archive_container(id), to: Containers
  defdelegate restore_container(id), to: Containers
  defdelegate delete_container(id), to: Containers

  defdelegate list_items(opts \\ %{}), to: Items
  defdelegate get_item(id), to: Items
  defdelegate create_item(attrs, actor_id), to: Items
  defdelegate update_item(id, attrs, actor_id), to: Items
  defdelegate delete_item(id), to: Items
  defdelegate move_item(id, attrs, actor_id), to: Items
  defdelegate set_item_maintenance(id, attrs, actor_id), to: Items

  # ALE-284a target item slice. The legacy `*_item` functions above stay
  # until ALE-289 removes them; target paths never write `inventory_history`.
  defdelegate resolve_operator_item(slug_or_id), to: OperatorItems
  defdelegate create_operator_item(attrs, actor_id), to: OperatorItems
  defdelegate update_operator_item(slug_or_id, attrs, actor_id), to: OperatorItems
  defdelegate change_operator_item_category(slug_or_id, attrs, actor_id), to: OperatorItems

  defdelegate list_item_history(id, opts \\ %{}), to: ItemHistory
  defdelegate list_history(opts \\ %{}), to: ItemHistory

  defdelegate get_stats(), to: Stats

  defdelegate list_definitions(category_id), to: Structure
  defdelegate get_definition(id), to: Structure
  defdelegate create_definition(category_id, attrs), to: Structure
  defdelegate update_definition(id, attrs), to: Structure
  defdelegate retire_definition(id), to: Structure
  defdelegate list_options(definition_id), to: Structure
  defdelegate get_option(id), to: Structure
  defdelegate create_option(definition_id, attrs), to: Structure
  defdelegate update_option(id, attrs), to: Structure
  defdelegate retire_option(id), to: Structure
end
