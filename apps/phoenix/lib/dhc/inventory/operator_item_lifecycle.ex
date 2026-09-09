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

  ## Serialization

  Every command runs in one outer transaction that first takes `FOR UPDATE`
  on the item row, so all interlocks (movement, maintenance, archive) queue
  behind each other per item. A loser sees a domain conflict tuple
  (`{:error, :loan_active}`, `{:error, :maintenance_open}`, …) and never a
  server error or an `Ecto` exception. Loan rows read for an interlock are
  locked `FOR UPDATE` in the same transaction so an approval racing the
  interlock cannot commit underneath the check.

  Availability itself is never stored — see `Dhc.Inventory.ItemProjection`.
  Target paths never write `inventory_history` and never touch
  `out_for_maintenance`. The loan commands are ALE-286; the viewer contract
  is ALE-284c.
  """

  import Ecto.Query

  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemGuards
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Inventory.ItemValues
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.MaintenancePeriod
  alias Dhc.Repo

  import ItemGuards,
    only: [
      lock_item: 1,
      lock_active_item: 1,
      item_query: 1,
      require_active_container: 1,
      require_active_container_chain: 1
    ]

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

  @default_archive_note "Ended automatically because the item was archived."
  @maintenance_rejection_note "Rejected automatically: the item went into maintenance."
  @archive_rejection_note "Rejected automatically: the item was archived."
  @max_reason_length 1000

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
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id) do
    Repo.transaction(fn -> locked_move(slug_or_id, attrs, actor_id) end) |> unwrap()
  end

  defp locked_move(slug_or_id, attrs, actor_id) do
    with {:ok, %Item{} = item} <- lock_active_item(slug_or_id),
         {:ok, container_id} <- require_active_container(take_container_id(attrs)),
         :ok <- refuse_active_loan(item.id) do
      item
      |> Ecto.Changeset.change(%{container_id: container_id, updated_by: actor_id})
      |> Repo.update!()
      |> ItemProjection.project()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

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
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id) do
    Repo.transaction(fn -> locked_start_maintenance(slug_or_id, attrs, actor_id) end) |> unwrap()
  end

  defp locked_start_maintenance(slug_or_id, attrs, actor_id) do
    with {:ok, %Item{} = item} <- lock_active_item(slug_or_id),
         {:ok, reason} <- require_reason(attrs),
         :ok <- refuse_open_maintenance(item.id),
         :ok <- refuse_active_loan(item.id),
         {:ok, _period} <- insert_period(item.id, reason, actor_id) do
      reject_pending_requests(item.id, actor_id, @maintenance_rejection_note)

      item
      |> Ecto.Changeset.change(%{updated_by: actor_id})
      |> Repo.update!()
      |> ItemProjection.project()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

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
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id) do
    Repo.transaction(fn -> locked_end_maintenance(slug_or_id, attrs, actor_id) end) |> unwrap()
  end

  defp locked_end_maintenance(slug_or_id, attrs, actor_id) do
    with {:ok, %Item{} = item} <- lock_active_item(slug_or_id),
         {:ok, note} <- optional_text(take_end_note(attrs)),
         {:ok, %MaintenancePeriod{} = period} <- lock_open_period(item.id) do
      close_period!(period, note, actor_id)

      item
      |> Ecto.Changeset.change(%{updated_by: actor_id})
      |> Repo.update!()
      |> ItemProjection.project()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Retained maintenance periods of one item, newest first.
  """
  @spec list_operator_item_maintenance_periods(String.t()) :: [maintenance_period()]
  def list_operator_item_maintenance_periods(slug_or_id) when is_binary(slug_or_id) do
    case Repo.one(item_query(slug_or_id)) do
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
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id) do
    Repo.transaction(fn -> locked_archive(slug_or_id, attrs, actor_id) end) |> unwrap()
  end

  defp locked_archive(slug_or_id, attrs, actor_id) do
    case lock_item(slug_or_id) do
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, %Item{archived_at: archived_at} = item} when not is_nil(archived_at) ->
        ItemProjection.project(item)

      {:ok, %Item{} = item} ->
        archive_active_item(item, attrs, actor_id)
    end
  end

  defp archive_active_item(%Item{} = item, attrs, actor_id) do
    with {:ok, reason} <- optional_text(take_reason(attrs)),
         :ok <- refuse_active_loan(item.id) do
      reject_pending_requests(item.id, actor_id, @archive_rejection_note)
      close_open_period_for_archive(item.id, reason, actor_id)

      item
      |> Ecto.Changeset.change(%{
        archived_at: DateTime.utc_now(),
        archived_by_principal_id: actor_id,
        updated_by: actor_id
      })
      |> Repo.update!()
      |> ItemProjection.project()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp close_open_period_for_archive(item_id, reason, actor_id) do
    case lock_open_period(item_id) do
      {:ok, %MaintenancePeriod{} = period} ->
        close_period!(period, archive_end_note(reason), actor_id)

      {:error, :no_open_maintenance} ->
        :ok
    end
  end

  defp archive_end_note(nil), do: @default_archive_note
  defp archive_end_note(reason), do: "Archived: " <> reason

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
      when is_binary(slug_or_id) and is_binary(actor_id) do
    Repo.transaction(fn -> locked_restore(slug_or_id, actor_id) end) |> unwrap()
  end

  defp locked_restore(slug_or_id, actor_id) do
    case lock_item(slug_or_id) do
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, %Item{archived_at: nil} = item} ->
        ItemProjection.project(item)

      {:ok, %Item{} = item} ->
        restore_archived_item(item, actor_id)
    end
  end

  defp restore_archived_item(%Item{} = item, actor_id) do
    with :ok <- require_active_category_of(item.category_id),
         :ok <- require_active_container_chain(item.container_id),
         :ok <- require_retained_values_valid(item) do
      item
      |> Ecto.Changeset.change(%{
        archived_at: nil,
        archived_by_principal_id: nil,
        updated_by: actor_id
      })
      |> Repo.update!()
      |> ItemProjection.project()
    else
      {:error, reason} -> Repo.rollback(reason)
      {:error, reason, info} -> Repo.rollback({reason, info})
    end
  end

  # Revalidate the stored values against the category's live definitions, so
  # a restore cannot resurrect an item that today's schema would reject.
  defp require_retained_values_valid(%Item{} = item) do
    definitions = ItemValues.load_definitions(item.category_id)

    case ItemValues.validate(definitions, stored_values_as_supplied(item.id)) do
      {:ok, _rows} -> :ok
      {:error, errors} -> {:error, :invalid_values, errors}
    end
  end

  # Re-present stored rows in the shape `validate/2` expects, so restore
  # applies exactly the same rules as create and edit.
  defp stored_values_as_supplied(item_id) do
    from(v in ItemPropertyValue, where: v.item_id == ^item_id)
    |> Repo.all()
    |> Map.new(&{&1.property_definition_id, supplied_value(&1)})
  end

  defp supplied_value(%ItemPropertyValue{option_id: option_id}) when not is_nil(option_id),
    do: option_id

  defp supplied_value(%ItemPropertyValue{boolean_value: boolean}) when is_boolean(boolean),
    do: boolean

  defp supplied_value(%ItemPropertyValue{decimal_value: decimal}) when not is_nil(decimal),
    do: decimal

  defp supplied_value(%ItemPropertyValue{text_value: text}), do: text

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
         {:ok, %Item{} = item} <- lock_item(slug_or_id),
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

  # ── Loan interlocks ─────────────────────────────────────────────

  # Locks the item's live loan rows before deciding, so a concurrent
  # approval either commits first (and is seen) or waits behind this
  # transaction.
  defp refuse_active_loan(item_id) do
    active? =
      from(l in Loan,
        where: l.item_id == ^item_id,
        where: l.status in ^ItemProjection.active_loan_statuses(),
        order_by: [asc: l.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Enum.any?()

    if active?, do: {:error, :loan_active}, else: :ok
  end

  defp reject_pending_requests(item_id, actor_id, note) do
    now = DateTime.utc_now()

    from(l in Loan, where: l.item_id == ^item_id, where: l.status == "requested")
    |> Repo.update_all(
      set: [
        status: "rejected",
        decided_at: now,
        decided_by_principal_id: actor_id,
        decision_note: note,
        updated_at: now
      ]
    )

    :ok
  end

  # ── Maintenance helpers ─────────────────────────────────────────

  defp refuse_open_maintenance(item_id) do
    case lock_open_period(item_id) do
      {:ok, %MaintenancePeriod{}} -> {:error, :maintenance_open}
      {:error, :no_open_maintenance} -> :ok
    end
  end

  defp lock_open_period(item_id) do
    query =
      from(p in MaintenancePeriod,
        where: p.item_id == ^item_id,
        where: is_nil(p.ended_at),
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :no_open_maintenance}
      %MaintenancePeriod{} = period -> {:ok, period}
    end
  end

  # The item lock already serializes command-against-command, so the partial
  # unique index is the backstop for anything that writes outside this seam.
  # Translate it rather than letting Postgrex raise: the ticket requires a
  # domain conflict, never a server error, on a race.
  defp insert_period(item_id, reason, actor_id) do
    %MaintenancePeriod{}
    |> Ecto.Changeset.change(%{
      item_id: item_id,
      started_at: DateTime.utc_now(),
      started_by_principal_id: actor_id,
      start_reason: reason
    })
    |> Ecto.Changeset.unique_constraint(:item_id,
      name: :inventory_maintenance_periods_one_open_per_item
    )
    |> Repo.insert()
    |> case do
      {:ok, %MaintenancePeriod{} = period} -> {:ok, period}
      {:error, %Ecto.Changeset{}} -> {:error, :maintenance_open}
    end
  end

  defp close_period!(%MaintenancePeriod{} = period, note, actor_id) do
    period
    |> Ecto.Changeset.change(%{
      ended_at: DateTime.utc_now(),
      ended_by_principal_id: actor_id,
      end_note: note
    })
    |> Repo.update!()
  end

  # A restore needs the category itself to still be live; an archived or
  # missing category cannot host an active item either way.
  defp require_active_category_of(category_id) do
    case ItemGuards.require_active_category(category_id) do
      {:ok, _id} -> :ok
      {:error, _reason} -> {:error, :archived_category}
    end
  end

  # ── Attribute normalization ─────────────────────────────────────

  defp take_container_id(attrs),
    do: take_first(attrs, ["containerId", "container_id", :containerId, :container_id])

  defp take_reason(attrs), do: take_first(attrs, ["reason", :reason])

  defp take_end_note(attrs),
    do: take_first(attrs, ["endNote", "end_note", :endNote, :end_note])

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

  # An item leaves circulation with a reason or not at all.
  defp require_reason(attrs) do
    case optional_text(take_reason(attrs)) do
      {:ok, nil} -> {:error, :reason_required}
      {:ok, reason} -> {:ok, reason}
      {:error, _invalid} -> {:error, :reason_required}
    end
  end

  # Blank text is absence, matching the item seam's notes rule; non-textual
  # input is rejected rather than silently coerced.
  defp optional_text(nil), do: {:ok, nil}

  defp optional_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      trimmed -> {:ok, String.slice(trimmed, 0, @max_reason_length)}
    end
  end

  defp optional_text(_other), do: {:error, :invalid_text}

  # ── Result translation ──────────────────────────────────────────

  defp unwrap({:ok, %Item{} = item}), do: {:ok, item}
  defp unwrap({:error, {:invalid_values, errors}}), do: {:error, :invalid_values, errors}
  defp unwrap({:error, reason}), do: {:error, reason}
end
