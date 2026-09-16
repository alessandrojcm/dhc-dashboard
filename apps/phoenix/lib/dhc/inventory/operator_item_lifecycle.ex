defmodule Dhc.Inventory.OperatorItemLifecycle do
  @moduledoc """
  ALE-284b: the availability-changing operator item commands.

  Where `Dhc.Inventory.OperatorItems` owns what an item *is* (identity,
  category, typed values, notes), this slice owns where it is and whether
  it is in circulation:

    * **Movement.** A dedicated command, never a general edit: it touches
      `container_id` and nothing else. Allowed during maintenance (servicing
      and storage are independent), blocked while a loan is approved or
      checked out because that loan holds custody.
    * **Maintenance periods.** Retained facts replacing the legacy
      `out_for_maintenance` boolean. Starting requires a reason and records
      the operator; at most one period per item is open, backed by the
      partial unique index `inventory_maintenance_periods_one_open_per_item`.
      Ending takes an optional note and records the closing operator. Start
      and end timestamps are kept forever.
    * **Archive.** Replaces destructive deletion for anything with loan or
      maintenance history. Archiving rejects pending requests, is blocked by
      an approved or checked-out loan, and atomically ends an open period
      with an archive reason. Restore is gated on active dependencies (the
      category and the whole container chain) and on the retained required
      values still validating.
    * **Delete.** Only for history-free items, and only with explicit
      confirmation.

  ## Where the work happens

  Since GH-508 every availability-changing command here — move, start and
  end maintenance, archive, restore — is a **facade** over one
  `Dhc.Inventory.AvailabilityCommands.execute/2` call as an `{:operator, id}`
  actor. That boundary owns the transaction, takes the item `FOR UPDATE`
  first so every interlock queues per item, locks the live loan rows under it,
  translates the one-open-period index into `:maintenance_open`, and projects
  the result through `Dhc.Inventory.ItemProjection`. A loser sees a domain
  conflict tuple (`{:error, :loan_active}`, `{:error, :maintenance_open}`, …)
  and never an `Ecto` exception. Nothing about a transition is decided here.

  Delete is not a transition — it destroys a history-free row — and the
  period listing is a read, so both stay in this module.

  Availability itself is never stored — see `Dhc.Inventory.ItemProjection`.
  """

  import Ecto.Query

  alias Dhc.Inventory.AvailabilityCommands
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemGuards
  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Inventory.ItemValues
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.MaintenancePeriod
  alias Dhc.Repo

  @type item :: Item.t()
  @type value_errors :: %{String.t() => ItemValues.error_reason()}

  @typedoc """
  A retained maintenance period. `open?` is derived from `ended_at`.
  """
  @type maintenance_period :: %{
          id: String.t(),
          item_id: String.t(),
          started_at: DateTime.t(),
          started_by_principal_id: String.t(),
          start_reason: String.t(),
          ended_at: DateTime.t() | nil,
          ended_by_principal_id: String.t() | nil,
          end_note: String.t() | nil,
          open?: boolean()
        }

  # ── Movement ────────────────────────────────────────────────────

  @doc """
  Move one item to another active container.

  This is never a general edit: `notes`, `values`, and `categoryId` in
  `attrs` are ignored, so a move can never quietly reclassify or re-value an
  item. Movement is permitted while the item is in maintenance and refused
  while a loan is approved or checked out.
  """
  @spec move_operator_item(String.t(), map(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :archived}
          | {:error, :archived_container}
          | {:error, :loan_active}
  def move_operator_item(slug_or_id, attrs, actor_id)
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:move_item, slug_or_id, attrs})

  # ── Maintenance ─────────────────────────────────────────────────

  @doc """
  Open a maintenance period on one item, effective immediately.

  The reason is required — an item leaves circulation with context or not at
  all. Pending requests are rejected in the same transaction so servicing
  never strands a member waiting on a decision; an approved or checked-out
  loan blocks the command instead, because that member already holds the
  item.
  """
  @spec start_operator_item_maintenance(String.t(), map(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :archived}
          | {:error, :reason_required}
          | {:error, :maintenance_open}
          | {:error, :loan_active}
  def start_operator_item_maintenance(slug_or_id, attrs, actor_id)
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:open_maintenance, slug_or_id, attrs})

  @doc """
  Close the item's open maintenance period, optionally with a note.

  Refused on an archived item, which is read-only: archiving already closed
  any open period atomically, so there is nothing left to end.
  """
  @spec end_operator_item_maintenance(String.t(), map(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :archived}
          | {:error, :no_open_maintenance}
  def end_operator_item_maintenance(slug_or_id, attrs, actor_id)
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:close_maintenance, slug_or_id, attrs})

  @doc """
  Retained maintenance periods of one item, newest first.
  """
  @spec list_operator_item_maintenance_periods(String.t()) :: [maintenance_period()]
  def list_operator_item_maintenance_periods(slug_or_id) when is_binary(slug_or_id) do
    case Repo.one(ItemGuards.item_query(slug_or_id)) do
      nil -> []
      %Item{id: item_id} -> list_periods(item_id)
    end
  end

  defp list_periods(item_id) do
    from(p in MaintenancePeriod,
      where: p.item_id == ^item_id,
      order_by: [desc: p.started_at, desc: p.id]
    )
    |> Repo.all()
    |> Enum.map(&period_view/1)
  end

  defp period_view(%MaintenancePeriod{} = period) do
    %{
      id: period.id,
      item_id: period.item_id,
      started_at: period.started_at,
      started_by_principal_id: period.started_by_principal_id,
      start_reason: period.start_reason,
      ended_at: period.ended_at,
      ended_by_principal_id: period.ended_by_principal_id,
      end_note: period.end_note,
      open?: is_nil(period.ended_at)
    }
  end

  # ── Archive ─────────────────────────────────────────────────────

  @doc """
  Archive one item instead of destroying it.

  Pending requests are rejected and any open maintenance period is closed in
  the same transaction, with the supplied reason recorded as the period's end
  note. An approved or checked-out loan blocks archival: a member holding the
  item outranks retirement. Archiving an already archived item is a no-op so
  a repeated command is not an error.
  """
  @spec archive_operator_item(String.t(), map(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :loan_active}
  def archive_operator_item(slug_or_id, attrs, actor_id)
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:retire_item, slug_or_id, attrs})

  @doc """
  Restore an archived item to circulation.

  Gated on the dependencies an active item needs: a live category, an
  entirely active container chain, and retained values that still satisfy the
  category's current definitions. The last gate matters because the
  make-required and retire gates only consider *active* items (ALE-283), so
  an archived item can legitimately drift out of validity while retired.
  Restoring an item that is not archived is a no-op.
  """
  @spec restore_operator_item(String.t(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :archived_category}
          | {:error, :archived_container}
          | {:error, :invalid_values, value_errors()}
  def restore_operator_item(slug_or_id, actor_id)
      when is_binary(slug_or_id) and is_binary(actor_id),
      do: command(actor_id, {:reactivate_item, slug_or_id, %{}})

  # ── Delete ──────────────────────────────────────────────────────

  @doc """
  Hard-delete a history-free item after explicit confirmation.

  Any loan or maintenance row makes the item historical, and history is
  never destroyed — archive it instead. Confirmation must be the boolean
  `true`; a truthy string is not consent.
  """
  @spec delete_operator_item(String.t(), map()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :confirmation_required}
          | {:error, :has_history}
  def delete_operator_item(slug_or_id, attrs) when is_binary(slug_or_id) and is_map(attrs) do
    Repo.transaction(fn -> locked_delete(slug_or_id, attrs) end) |> unwrap()
  end

  defp locked_delete(slug_or_id, attrs) do
    with :ok <- require_confirmation(attrs),
         {:ok, %Item{} = item} <- ItemGuards.lock_item(slug_or_id),
         :ok <- refuse_history(item.id) do
      from(v in ItemPropertyValue, where: v.item_id == ^item.id) |> Repo.delete_all()
      Repo.delete!(item)
      %Item{item | availability: %{available?: false, status: :archived}}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp refuse_history(item_id) do
    if history?(item_id), do: {:error, :has_history}, else: :ok
  end

  defp history?(item_id) do
    loans? = from(l in Loan, where: l.item_id == ^item_id) |> Repo.exists?()

    periods? =
      from(p in MaintenancePeriod, where: p.item_id == ^item_id) |> Repo.exists?()

    loans? or periods?
  end

  defp require_confirmation(attrs) do
    case take_confirm(attrs) do
      true -> :ok
      _other -> {:error, :confirmation_required}
    end
  end

  # ── Attribute normalization ─────────────────────────────────────

  defp take_confirm(attrs), do: take_first(attrs, ["confirm", :confirm])

  defp take_first(attrs, keys) do
    Enum.find_value(keys, fn key ->
      if is_map_key(attrs, key), do: {:present, Map.get(attrs, key)}, else: nil
    end)
    |> case do
      nil -> nil
      {:present, value} -> value
    end
  end

  # ── Result translation ──────────────────────────────────────────

  # The boundary reports restore's value errors as one tagged reason; this
  # seam's contract is the three-tuple, so translate at the edge.
  defp command(actor_id, command) do
    case AvailabilityCommands.execute({:operator, actor_id}, command) do
      {:ok, {:item, %Item{} = item}} -> {:ok, item}
      {:error, {:invalid_values, errors}} -> {:error, :invalid_values, errors}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap({:ok, %Item{} = item}), do: {:ok, item}
  defp unwrap({:error, reason}), do: {:error, reason}
end
