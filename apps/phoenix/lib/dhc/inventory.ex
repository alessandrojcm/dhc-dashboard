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
  alias Dhc.Inventory.MemberCatalog
  alias Dhc.Inventory.MemberLoans
  alias Dhc.Inventory.OperatorItemLifecycle
  alias Dhc.Inventory.OperatorItemList
  alias Dhc.Inventory.OperatorItems
  alias Dhc.Inventory.OperatorLoans
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
  # ALE-284c paginated operator read backing the viewer contract.
  defdelegate list_operator_items(params \\ %{}), to: OperatorItemList
  defdelegate create_operator_item(attrs, actor_id), to: OperatorItems
  defdelegate update_operator_item(slug_or_id, attrs, actor_id), to: OperatorItems
  defdelegate change_operator_item_category(slug_or_id, attrs, actor_id), to: OperatorItems

  # ALE-284b availability-changing commands. Each serializes on the item and
  # returns a domain conflict on races; availability stays a projection.
  defdelegate move_operator_item(slug_or_id, attrs, actor_id), to: OperatorItemLifecycle

  defdelegate start_operator_item_maintenance(slug_or_id, attrs, actor_id),
    to: OperatorItemLifecycle

  defdelegate end_operator_item_maintenance(slug_or_id, attrs, actor_id),
    to: OperatorItemLifecycle

  defdelegate list_operator_item_maintenance_periods(slug_or_id), to: OperatorItemLifecycle
  defdelegate archive_operator_item(slug_or_id, attrs, actor_id), to: OperatorItemLifecycle
  defdelegate restore_operator_item(slug_or_id, actor_id), to: OperatorItemLifecycle
  defdelegate delete_operator_item(slug_or_id, attrs), to: OperatorItemLifecycle

  # ALE-285 member catalog. A separate read model, not a role variant of the
  # operator viewer: member rows never carry container, notes, or operator
  # maintenance facts, and availability is a generic reason (story 45).
  defdelegate list_catalog_items(params \\ %{}), to: MemberCatalog
  defdelegate resolve_catalog_item(slug_or_id), to: MemberCatalog

  # ALE-285 member loan commands and own history. A member acts only on their
  # own loans and only before checkout; approve/reject/checkout/return and the
  # operator queue are ALE-286.
  defdelegate request_loan(slug_or_id, attrs, borrower_id), to: MemberLoans
  defdelegate cancel_loan(loan_id, attrs, borrower_id), to: MemberLoans
  defdelegate list_own_loans(borrower_id, params \\ %{}), to: MemberLoans
  defdelegate get_own_loan(loan_id, borrower_id), to: MemberLoans

  # ALE-296 (286a) operator loan transitions. Each locks the item before the
  # loan and returns a domain conflict on a race; approval reserves the item
  # exactly once and rejects every competing request. Notifications are
  # ALE-287 and deliberately absent — the API exposure is ALE-286c. Operator
  # cancel applies only to an approved loan; the member's own cancellation
  # stays in `MemberLoans`.
  defdelegate approve_loan(loan_id, attrs, actor_id), to: OperatorLoans
  defdelegate reject_loan(loan_id, attrs, actor_id), to: OperatorLoans
  defdelegate cancel_operator_loan(loan_id, attrs, actor_id), to: OperatorLoans
  defdelegate check_out_loan(loan_id, attrs, actor_id), to: OperatorLoans
  defdelegate return_loan(loan_id, actor_id), to: OperatorLoans
  defdelegate edit_loan_dates(loan_id, attrs, actor_id), to: OperatorLoans
  defdelegate get_operator_loan(loan_id), to: OperatorLoans

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
