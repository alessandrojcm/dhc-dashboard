defmodule Dhc.Inventory.ItemProjection do
  @moduledoc """
  ALE-284a/b: the one place a target item row becomes a read model.

  Both the item seam (`Dhc.Inventory.OperatorItems`) and the lifecycle seam
  (`Dhc.Inventory.OperatorItemLifecycle`) return items through here, so a
  derived label and an availability status can never drift between them.

  **Availability is a projection, never a stored flag** (spec ALE-280): it
  is recomputed from the archive timestamp, the open maintenance period, and
  the approved/checked-out loans every time an item is read. A pending
  request is deliberately not an availability input — until approval there is
  no entitlement (story 34), so competing requests coexist on an available
  item.

  Status precedence is `:archived`, then `:maintenance`, then `:on_loan`,
  then `:available`. Archive outranks the rest because an archived item is
  out of circulation regardless of why it left, and archiving atomically
  closes any open period anyway.
  """

  import Ecto.Query

  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemValues
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.MaintenancePeriod
  alias Dhc.Repo

  @label_separator " · "

  @typedoc "Statuses that make an item unavailable, plus `:available`."
  @type availability_status :: :available | :maintenance | :on_loan | :archived

  @type availability :: %{available?: boolean(), status: availability_status()}

  # Loan statuses that hold custody or a reservation of the item. `requested`
  # is absent on purpose; `rejected`, `cancelled`, and `returned` are closed.
  @active_loan_statuses ~w(approved checked_out)

  @doc """
  Statuses whose presence means a loan currently holds the item.
  """
  @spec active_loan_statuses() :: [String.t()]
  def active_loan_statuses, do: @active_loan_statuses

  @doc """
  Project one item row into its read model.

  Populates the container and category summaries, the typed values, the
  server-derived label, and the availability projection.
  """
  @spec project(Item.t()) :: Item.t()
  def project(%Item{} = item) do
    values = ItemValues.list_values(item.id)
    category = category_summary(item.category_id)

    %Item{
      item
      | container: container_summary(item.container_id),
        category: category,
        values: values,
        label: derive_label(category && category["name"], item.slug, values),
        availability: availability(item)
    }
  end

  @doc """
  Project a whole page of item rows in a fixed number of queries.

  `project/1` is the single-item read and issues its aggregates per row,
  which a paginated list would turn into N+1. This form batches the values,
  container and category summaries, open maintenance periods, and active
  loans across `items`, so a page costs the same number of queries whatever
  its size. The resulting read model is identical to `project/1`.
  """
  @spec project_all([Item.t()]) :: [Item.t()]
  def project_all([]), do: []

  def project_all(items) when is_list(items) do
    item_ids = Enum.map(items, & &1.id)
    values_by_item = ItemValues.list_values_by_item(item_ids)
    containers = container_summaries(items)
    categories = category_summaries(items)
    availabilities = availability_by_item(items)

    Enum.map(items, fn %Item{} = item ->
      values = Map.get(values_by_item, item.id, [])
      category = Map.get(categories, item.category_id)

      %Item{
        item
        | container: Map.get(containers, item.container_id),
          category: category,
          values: values,
          label: derive_label(category && category["name"], item.slug, values),
          availability: Map.fetch!(availabilities, item.id)
      }
    end)
  end

  @doc """
  Recompute the availability of a whole page of items in a fixed number of
  queries, keyed by item id.

  The batched counterpart of `availability/1`, extracted so every paginated
  read — operator or member — decides availability from the same precedence
  rules without either duplicating the maintenance and loan queries or
  paying them per row.
  """
  @spec availability_by_item([Item.t()]) :: %{String.t() => availability()}
  def availability_by_item([]), do: %{}

  def availability_by_item(items) when is_list(items) do
    item_ids = Enum.map(items, & &1.id)
    maintained = open_maintenance_ids(item_ids)
    on_loan = active_loan_ids(item_ids)

    Map.new(items, fn %Item{} = item ->
      {item.id,
       batched_availability(item, MapSet.member?(maintained, item.id),
         on_loan: MapSet.member?(on_loan, item.id)
       )}
    end)
  end

  @doc """
  Derive an item's display label from its category and identifying values.

  Returns the category name joined with each identifying property value in
  order, or the category name plus the slug when no identifying value is
  present. Never stored.
  """
  @spec derive_label(String.t() | nil, String.t() | nil, [ItemValues.value_view()]) :: String.t()
  def derive_label(category_name, slug, values) do
    identifying =
      values
      |> Enum.filter(&is_integer(&1.identifying_position))
      |> Enum.sort_by(& &1.identifying_position)
      |> Enum.map(&render_value/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    parts = if identifying == [], do: [slug], else: identifying

    [category_name | parts]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(@label_separator)
  end

  @doc """
  Recompute an item's availability from its current facts.
  """
  @spec availability(Item.t()) :: availability()
  def availability(%Item{archived_at: archived_at}) when not is_nil(archived_at),
    do: unavailable(:archived)

  def availability(%Item{id: item_id}) do
    cond do
      open_maintenance?(item_id) -> unavailable(:maintenance)
      active_loan?(item_id) -> unavailable(:on_loan)
      true -> %{available?: true, status: :available}
    end
  end

  @doc """
  Whether `item_id` has an open (unended) maintenance period.
  """
  @spec open_maintenance?(String.t()) :: boolean()
  def open_maintenance?(item_id) when is_binary(item_id) do
    from(p in MaintenancePeriod, where: p.item_id == ^item_id, where: is_nil(p.ended_at))
    |> Repo.exists?()
  end

  @doc """
  Whether `item_id` is held by an approved or checked-out loan.
  """
  @spec active_loan?(String.t()) :: boolean()
  def active_loan?(item_id) when is_binary(item_id) do
    from(l in Loan, where: l.item_id == ^item_id, where: l.status in @active_loan_statuses)
    |> Repo.exists?()
  end

  # Same precedence as `availability/1`, decided from pre-fetched sets rather
  # than a query per item.
  defp batched_availability(%Item{archived_at: archived_at}, _maintenance?, _opts)
       when not is_nil(archived_at),
       do: unavailable(:archived)

  defp batched_availability(%Item{}, true, _opts), do: unavailable(:maintenance)

  defp batched_availability(%Item{}, false, on_loan: true), do: unavailable(:on_loan)

  defp batched_availability(%Item{}, false, on_loan: false),
    do: %{available?: true, status: :available}

  defp open_maintenance_ids(item_ids) do
    from(p in MaintenancePeriod,
      where: p.item_id in ^item_ids,
      where: is_nil(p.ended_at),
      select: p.item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp active_loan_ids(item_ids) do
    from(l in Loan,
      where: l.item_id in ^item_ids,
      where: l.status in @active_loan_statuses,
      select: l.item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp container_summaries(items) do
    ids = items |> Enum.map(& &1.container_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(c in "containers",
        where: c.id in ^Enum.map(ids, &Ecto.UUID.dump!/1),
        select: %{
          "id" => fragment("?::text", c.id),
          "name" => c.name,
          "archived_at" => c.archived_at
        }
      )
      |> Repo.all()
      |> Map.new(&{&1["id"], &1})
    end
  end

  defp category_summaries(items) do
    ids = items |> Enum.map(& &1.category_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(c in EquipmentCategory,
        where: c.id in ^ids,
        select: %{"id" => c.id, "name" => c.name, "archived_at" => c.archived_at}
      )
      |> Repo.all()
      |> Map.new(&{&1["id"], &1})
    end
  end

  defp unavailable(status), do: %{available?: false, status: status}

  defp render_value(%{value_type: "text", text: text}), do: text
  defp render_value(%{value_type: "decimal", decimal: nil}), do: nil
  defp render_value(%{value_type: "decimal", decimal: decimal}), do: Decimal.to_string(decimal)
  defp render_value(%{value_type: "boolean", boolean: true}), do: "Yes"
  defp render_value(%{value_type: "boolean", boolean: false}), do: "No"
  defp render_value(%{value_type: "boolean"}), do: nil
  defp render_value(%{value_type: "single_select", option_label: label}), do: label
  defp render_value(_value), do: nil

  defp container_summary(nil), do: nil

  defp container_summary(container_id) do
    from(c in "containers",
      where: c.id == type(^container_id, :binary_id),
      select: %{
        "id" => fragment("?::text", c.id),
        "name" => c.name,
        "archived_at" => c.archived_at
      }
    )
    |> Repo.one()
  end

  defp category_summary(nil), do: nil

  defp category_summary(category_id) do
    from(c in EquipmentCategory,
      where: c.id == ^category_id,
      select: %{"id" => c.id, "name" => c.name, "archived_at" => c.archived_at}
    )
    |> Repo.one()
  end
end
