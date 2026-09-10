defmodule Dhc.Inventory.OperatorItems do
  @moduledoc """
  ALE-284a: operator administration of target inventory items.

  One row of `inventory_items` is one physical unit. This slice owns the
  target item lifecycle behind the `Dhc.Inventory` seam:

    * **Slug.** Every target item is minted with an immutable,
      server-generated, human-readable slug (`item-000001`) drawn from
      `inventory_item_slug_seq`. It is the item's identity: stable across
      category changes, never operator-writable, and the resolution key
      alongside the id.
    * **Derived label.** The visible label is computed from the category
      name plus that category's ordered identifying property values, with
      the slug as the fallback when no identifying value is present. It is
      never stored — reordering identifying definitions changes
      presentation, not identity.
    * **Typed values.** Create, edit, and category change validate the
      supplied values against definitions reloaded (and share-locked) in
      the same transaction, reporting per-definition errors. Empty text is
      absence; boolean `false` is a real value. There are no defaults.
    * **Duplicates.** Identical category/property combinations are allowed
      because the slug distinguishes the physical units.
    * **Category change.** Reclassification is one atomic command that must
      supply every value the new category requires, with the operator
      mapping old values explicitly. Partial reclassification is impossible.
    * **Notes.** Plain-text current facts with no audit history.

  Target paths ignore legacy columns: they never write `inventory_history`
  and never touch `photo_url`, `attributes`, or `out_for_maintenance`.
  `quantity` is server-set to 1 solely to satisfy the surviving NOT NULL
  until ALE-289 removes the column.

  Movement, maintenance periods, and archive interlocks live in
  `Dhc.Inventory.OperatorItemLifecycle` (ALE-284b); the viewer contract is
  ALE-284c. Editing an archived item is refused here — restoring it first is
  the way back. Reads project through `Dhc.Inventory.ItemProjection`, which
  also owns the availability projection.
  """

  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemGuards
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.ItemValues
  alias Dhc.Repo

  import ItemGuards,
    only: [lock_active_item: 1, require_active_container: 1, require_active_category: 1]

  @type item :: Item.t()
  @type value_errors :: %{String.t() => ItemValues.error_reason()}

  defdelegate derive_label(category_name, slug, values), to: ItemProjection

  # ── Reads ───────────────────────────────────────────────────────

  @doc """
  Resolve one item by slug or id, with its derived label and typed values.
  """
  @spec resolve_operator_item(String.t()) :: {:ok, item()} | {:error, :not_found}
  def resolve_operator_item(slug_or_id) when is_binary(slug_or_id) do
    case fetch_item(slug_or_id) do
      nil -> {:error, :not_found}
      %Item{} = item -> {:ok, ItemProjection.project(item)}
    end
  end

  # ── Create ──────────────────────────────────────────────────────

  @doc """
  Create one physical unit with a minted slug and validated typed values.
  """
  @spec create_operator_item(map(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :archived_container}
          | {:error, :archived_category}
          | {:error, :invalid_notes}
          | {:error, :invalid_values, value_errors()}
          | {:error, Ecto.Changeset.t()}
  def create_operator_item(attrs, actor_id) when is_map(attrs) and is_binary(actor_id) do
    attrs = normalize_attrs(attrs)

    Repo.transaction(fn -> insert_item(attrs, actor_id) end)
    |> unwrap()
  end

  defp insert_item(attrs, actor_id) do
    with {:ok, container_id} <- require_active_container(attrs[:container_id]),
         {:ok, category_id} <- require_active_category(attrs[:category_id]),
         {:ok, notes} <- normalize_notes(attrs[:notes]),
         definitions = ItemValues.load_definitions(category_id),
         {:ok, rows} <- validate_values(definitions, attrs[:values] || %{}) do
      item = insert_row(container_id, category_id, notes, actor_id)
      ItemValues.insert_all(item.id, rows)
      ItemProjection.project(item)
    else
      {:error, reason} -> Repo.rollback(reason)
      {:error, reason, info} -> Repo.rollback({reason, info})
    end
  end

  defp insert_row(container_id, category_id, notes, actor_id) do
    %Item{created_by: actor_id, slug: mint_slug()}
    |> Ecto.Changeset.change(%{
      container_id: container_id,
      category_id: category_id,
      notes: notes,
      # Only to satisfy the surviving legacy NOT NULL; ALE-289 drops it.
      quantity: 1
    })
    |> Ecto.Changeset.validate_length(:notes, max: 1000)
    |> Repo.insert!()
  end

  # ── Edit ────────────────────────────────────────────────────────

  @doc """
  Edit an item's notes and typed values.

  This is never a movement, maintenance, archive, or loan command: a
  supplied `containerId` is ignored, and the category only changes through
  `change_operator_item_category/3`. Omitting `values` leaves the stored
  values untouched; supplying it replaces the complete set, so an omitted
  definition becomes absent.
  """
  @spec update_operator_item(String.t(), map(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :archived}
          | {:error, :invalid_notes}
          | {:error, :invalid_values, value_errors()}
          | {:error, Ecto.Changeset.t()}
  def update_operator_item(slug_or_id, attrs, actor_id)
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id) do
    attrs = normalize_attrs(attrs)

    Repo.transaction(fn -> edit_item(slug_or_id, attrs, actor_id) end)
    |> unwrap()
  end

  defp edit_item(slug_or_id, attrs, actor_id) do
    with {:ok, %Item{} = item} <- lock_active_item(slug_or_id),
         {:ok, notes} <- normalize_edit_notes(attrs),
         definitions = ItemValues.load_definitions(item.category_id),
         {:ok, rows} <- validate_edit_values(definitions, item, attrs) do
      maybe_replace_values(item.id, attrs, rows)

      item
      |> apply_notes(notes)
      |> Ecto.Changeset.put_change(:updated_by, actor_id)
      |> Ecto.Changeset.validate_length(:notes, max: 1000)
      |> Repo.update!()
      |> ItemProjection.project()
    else
      {:error, reason} -> Repo.rollback(reason)
      {:error, reason, info} -> Repo.rollback({reason, info})
    end
  end

  # An edit that omits `values` must still validate nothing: the stored set
  # is already valid and stays untouched.
  defp validate_edit_values(_definitions, _item, %{values: nil}), do: {:ok, nil}

  defp validate_edit_values(definitions, _item, %{values: values}),
    do: validate_values(definitions, values)

  defp maybe_replace_values(_item_id, %{values: nil}, _rows), do: :ok
  defp maybe_replace_values(item_id, _attrs, rows), do: ItemValues.replace_all(item_id, rows)

  # `:skip` keeps an omitted `notes` untouched; a supplied one always applies.
  defp apply_notes(%Item{} = item, :skip), do: Ecto.Changeset.change(item, %{})
  defp apply_notes(%Item{} = item, notes), do: Ecto.Changeset.change(item, %{notes: notes})

  defp normalize_edit_notes(attrs) do
    case Map.fetch(attrs, :notes) do
      :error -> {:ok, :skip}
      {:ok, notes} -> normalize_notes(notes)
    end
  end

  # ── Category change ─────────────────────────────────────────────

  @doc """
  Move one item to a different category in one atomic edit.

  The supplied values are validated against the **new** category's live
  definitions, so every value it requires must be present. Old values are
  retained only through explicit operator mapping onto the new
  definitions; anything unmapped stops being a current fact. The slug is
  unaffected.
  """
  @spec change_operator_item_category(String.t(), map(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :archived}
          | {:error, :archived_category}
          | {:error, :invalid_values, value_errors()}
  def change_operator_item_category(slug_or_id, attrs, actor_id)
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(actor_id) do
    attrs = normalize_attrs(attrs)

    Repo.transaction(fn -> reclassify_item(slug_or_id, attrs, actor_id) end)
    |> unwrap()
  end

  defp reclassify_item(slug_or_id, attrs, actor_id) do
    with {:ok, %Item{} = item} <- lock_active_item(slug_or_id),
         {:ok, category_id} <- require_active_category(attrs[:category_id]),
         definitions = ItemValues.load_definitions(category_id),
         {:ok, rows} <- validate_values(definitions, attrs[:values] || %{}) do
      ItemValues.replace_all(item.id, rows)

      item
      |> Ecto.Changeset.change(%{category_id: category_id, updated_by: actor_id})
      |> Repo.update!()
      |> ItemProjection.project()
    else
      {:error, reason} -> Repo.rollback(reason)
      {:error, reason, info} -> Repo.rollback({reason, info})
    end
  end

  # ── Slug ────────────────────────────────────────────────────────

  defp mint_slug do
    %{rows: [[value]]} = Repo.query!("SELECT nextval('inventory_item_slug_seq')", [])
    "item-" <> String.pad_leading(to_string(value), 6, "0")
  end

  # ── Guards ──────────────────────────────────────────────────────

  defp fetch_item(slug_or_id) do
    Repo.one(ItemGuards.item_query(slug_or_id))
  end

  defp validate_values(definitions, values) do
    case ItemValues.validate(definitions, values) do
      {:ok, rows} -> {:ok, rows}
      {:error, errors} -> {:error, :invalid_values, errors}
    end
  end

  # ── Attr normalization ──────────────────────────────────────────

  defp normalize_attrs(attrs) do
    [
      {:container_id, ["containerId", "container_id", :containerId, :container_id]},
      {:category_id, ["categoryId", "category_id", :categoryId, :category_id]},
      {:notes, ["notes", :notes]},
      {:values, ["values", :values]}
    ]
    |> Enum.reduce(%{}, fn {dest, sources}, acc ->
      case first_present(attrs, sources) do
        :absent -> acc
        {:present, value} -> Map.put(acc, dest, value)
      end
    end)
    |> normalize_values_key()
  end

  # `values` distinguishes "omitted" (leave stored values alone) from
  # "supplied" (replace the complete set), so absent stays absent while a
  # supplied nil normalizes to the empty set.
  defp normalize_values_key(attrs) do
    case Map.fetch(attrs, :values) do
      :error -> Map.put(attrs, :values, nil)
      {:ok, nil} -> Map.put(attrs, :values, %{})
      {:ok, values} when is_map(values) -> attrs
      {:ok, _other} -> Map.put(attrs, :values, %{})
    end
  end

  defp first_present(attrs, sources) do
    Enum.find_value(sources, :absent, fn key ->
      if is_map_key(attrs, key), do: {:present, Map.get(attrs, key)}, else: nil
    end)
  end

  # Notes are plain text. Empty or whitespace-only clears them; anything
  # non-textual is rejected rather than silently dropped.
  defp normalize_notes(nil), do: {:ok, nil}

  defp normalize_notes(notes) when is_binary(notes) do
    case String.trim(notes) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_notes(_notes), do: {:error, :invalid_notes}

  # ── Result translation ──────────────────────────────────────────

  defp unwrap({:ok, %Item{} = item}), do: {:ok, item}
  defp unwrap({:error, {:invalid_values, errors}}), do: {:error, :invalid_values, errors}
  defp unwrap({:error, reason}), do: {:error, reason}
end
