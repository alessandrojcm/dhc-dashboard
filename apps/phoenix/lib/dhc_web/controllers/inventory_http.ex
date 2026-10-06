defmodule DhcWeb.InventoryHTTP do
  @moduledoc """
  The problem fallback for every Inventory HTTP slice: categories,
  containers, structure, operator items, the member catalog, member loans
  and operator loans.

  Controllers return the domain result; where one domain atom needs two
  details in this family (`:not_found` naming a Loan rather than an Item, or
  `:still_referenced` naming a Category rather than an Option) the controller
  renames it to the reason below. Reasons that share one public code declare
  it as the third element.
  """

  use DhcWeb.Problem,
    reasons: %{
      # ── 404 ──────────────────────────────────────────────────────
      not_found: {404, "Item not found"},
      loan_not_found: {404, "Loan not found"},
      category_not_found: {404, "Category not found"},
      container_not_found: {404, "Container not found"},
      definition_not_found: {404, "Definition not found"},
      option_not_found: {404, "Option not found"},

      # ── 400 list/query parameters ────────────────────────────────
      invalid_limit: {400, "limit must be one of 10, 25, 50, 100"},
      invalid_direction: {400, "direction must be asc or desc"},
      invalid_archived: {400, "archived must be exclude, include, or only"},
      invalid_category: {400, "categoryId must be comma-separated category UUIDs"},
      invalid_property: {400, "property must be comma-separated definitionId:value pairs"},
      invalid_availability: {400, "availability must be one of all, available, unavailable"},
      invalid_status: {400, "status must be all, open, or closed"},
      bad_cursor: {400, "cursor does not match the current query"},

      # ── 409 interlocks ───────────────────────────────────────────
      archived: {409, "The item is archived and therefore read-only"},
      loan_active: {409, "An approved or checked-out loan holds this item"},
      maintenance_open: {409, "The item has an open maintenance period"},
      no_open_maintenance: {409, "The item has no open maintenance period"},
      has_history: {409, "The item has loan or maintenance history — archive it instead"},
      retry_exhausted: {409, "The item's container kept changing; try restore again"},
      # `item_unavailable` intentionally explains nothing further: a member
      # must not learn who holds an item or why it is out.
      item_unavailable: {409, "The item cannot be requested right now"},
      allocation_unavailable: {409, "The item is not available to allocate", :item_unavailable},
      duplicate_request: {409, "You already have a pending request for this item"},
      not_cancellable: {409, "This loan can no longer be cancelled"},
      not_pending: {409, "The loan is not a pending request"},
      not_approved: {409, "The loan is not approved"},
      not_checked_out: {409, "The loan is not checked out"},
      not_editable: {409, "The loan's dates are no longer editable"},
      already_allocated: {409, "Another loan already holds this item"},
      start_immutable: {409, "The start date cannot change after checkout"},
      outside_window: {409, "Today is outside the approved loan window"},
      active_dependants: {409, "container still has active child containers or items"},
      category_name_taken: {409, "A category with that name already exists"},
      definition_label_taken: {409, "A definition with that label already exists"},
      option_label_taken: {409, "An option with that label already exists"},
      category_still_referenced:
        {409, "Category is still referenced by inventory items", :still_referenced},
      container_still_referenced:
        {409, "Container still has child containers or inventory items", :still_referenced},
      definition_still_referenced:
        {409, "definition is still referenced by active item values", :still_referenced},
      option_still_referenced:
        {409, "option is still referenced by active item values", :still_referenced},

      # ── 422 validation ───────────────────────────────────────────
      invalid_values: {422, "One or more property values are invalid"},
      invalid_notes: {422, "notes must be text"},
      invalid_note: {422, "note must be text"},
      archived_category: {422, "The category is archived"},
      archived_container: {422, "The container is archived"},
      reason_required: {422, "A maintenance reason is required"},
      confirmation_required: {422, "Deletion requires explicit confirmation"},
      invalid_dates:
        {422, "startsOn and dueOn must be dates today or later, with dueOn on or after startsOn"},
      invalid_loan_dates: {422, "dates are invalid", :invalid_dates},
      circular_parent: {422, "parentContainerId would create a cycle"},
      archived_parent: {422, "parentContainerId must refer to an active container"},
      type_immutable: {422, "valueType cannot change once the definition is used"},
      required_blocked: {422, "required cannot be set until every active item has a valid value"},
      not_single_select: {422, "options are only allowed on single_select definitions"},
      retired_option: {422, "a retired option cannot be updated"},

      # ── 500 ──────────────────────────────────────────────────────
      notification_enqueue_failed: {500, "Failed to enqueue notification"}
    },
    fields: %{
      parent_container_id: "parentContainerId",
      container_id: "containerId",
      category_id: "categoryId",
      value_type: "valueType",
      identifying_position: "identifyingPosition",
      starts_on: "startsOn",
      due_on: "dueOn"
    }

  @doc """
  Per-definition value failures as problem fields:
  `%{definition_id => reason}` → `%{"values.<definitionId>" => ["reason"]}`.
  """
  def value_fields(value_errors) do
    Map.new(value_errors, fn {definition_id, reason} ->
      {"values.#{definition_id}", [to_string(reason)]}
    end)
  end

  @doc "Active items blocking a required definition, as problem fields."
  def blocking_item_fields(item_ids) do
    Map.new(item_ids, &{"items.#{&1}", ["has no valid value"]})
  end
end
