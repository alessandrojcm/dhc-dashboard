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

  Movement, maintenance periods, and archive interlocks are ALE-284b; the
  viewer contract is ALE-284c. Editing an already archived item is refused
  here so the read-only rule holds before those commands exist.
  """

  import Ecto.Query

  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemValues
  alias Dhc.Repo

  @type item :: Item.t()
  @type value_errors :: %{String.t() => ItemValues.error_reason()}

  @label_separator " · "

  # ── Reads ───────────────────────────────────────────────────────

  @doc """
  Resolve one item by slug or id, with its derived label and typed values.
  """
  @spec resolve_operator_item(String.t()) :: {:ok, item()} | {:error, :not_found}
  def resolve_operator_item(slug_or_id) when is_binary(slug_or_id) do
    case fetch_item(slug_or_id) do
      nil -> {:error, :not_found}
      %Item{} = item -> {:ok, project(item)}
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
         definitions = ItemValues.load_definitions(category_id),
         {:ok, rows} <- validate_values(definitions, attrs[:values] || %{}) do
      item = insert_row(container_id, category_id, attrs, actor_id)
      ItemValues.insert_all(item.id, rows)
      project(item)
    else
      {:error, reason} -> Repo.rollback(reason)
      {:error, reason, info} -> Repo.rollback({reason, info})
    end
  end

  defp insert_row(container_id, category_id, attrs, actor_id) do
    %Item{created_by: actor_id, slug: mint_slug()}
    |> Ecto.Changeset.change(%{
      container_id: container_id,
      category_id: category_id,
      notes: normalize_notes(attrs[:notes]),
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
         definitions = ItemValues.load_definitions(item.category_id),
         {:ok, rows} <- validate_edit_values(definitions, item, attrs) do
      maybe_replace_values(item.id, attrs, rows)

      item
      |> apply_notes(attrs)
      |> Ecto.Changeset.put_change(:updated_by, actor_id)
      |> Ecto.Changeset.validate_length(:notes, max: 1000)
      |> Repo.update!()
      |> project()
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

  defp apply_notes(%Item{} = item, attrs) do
    case Map.fetch(attrs, :notes) do
      {:ok, notes} -> Ecto.Changeset.change(item, %{notes: normalize_notes(notes)})
      :error -> Ecto.Changeset.change(item, %{})
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
      |> project()
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

  # ── Derived label ───────────────────────────────────────────────

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

  defp render_value(%{value_type: "text", text: text}), do: text
  defp render_value(%{value_type: "decimal", decimal: nil}), do: nil
  defp render_value(%{value_type: "decimal", decimal: decimal}), do: Decimal.to_string(decimal)
  defp render_value(%{value_type: "boolean", boolean: true}), do: "Yes"
  defp render_value(%{value_type: "boolean", boolean: false}), do: "No"
  defp render_value(%{value_type: "boolean"}), do: nil
  defp render_value(%{value_type: "single_select", option_label: label}), do: label
  defp render_value(_value), do: nil

  # ── Projection ──────────────────────────────────────────────────

  defp project(%Item{} = item) do
    values = ItemValues.list_values(item.id)
    container = container_summary(item.container_id)
    category = category_summary(item.category_id)

    %Item{
      item
      | container: container,
        category: category,
        values: values,
        label: derive_label(category && category["name"], item.slug, values)
    }
  end

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

  # ── Guards ──────────────────────────────────────────────────────

  defp fetch_item(slug_or_id) do
    Repo.one(item_query(slug_or_id))
  end

  defp lock_active_item(slug_or_id) do
    case slug_or_id |> item_query() |> lock("FOR UPDATE") |> Repo.one() do
      nil -> {:error, :not_found}
      %Item{archived_at: archived_at} when not is_nil(archived_at) -> {:error, :archived}
      %Item{} = item -> {:ok, item}
    end
  end

  defp item_query(slug_or_id) do
    case Ecto.UUID.cast(slug_or_id) do
      {:ok, id} -> from(i in Item, where: i.id == ^id)
      :error -> from(i in Item, where: i.slug == ^slug_or_id)
    end
  end

  defp require_active_container(nil), do: {:error, :not_found}

  defp require_active_container(container_id) do
    case Ecto.UUID.cast(container_id) do
      :error -> {:error, :not_found}
      {:ok, id} -> check_container(id)
    end
  end

  defp check_container(id) do
    query =
      from(c in "containers",
        where: c.id == type(^id, :binary_id),
        select: %{archived_at: c.archived_at},
        lock: "FOR SHARE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %{archived_at: nil} -> {:ok, id}
      %{archived_at: _archived} -> {:error, :archived_container}
    end
  end

  defp require_active_category(nil), do: {:error, :not_found}

  defp require_active_category(category_id) do
    case Ecto.UUID.cast(category_id) do
      :error -> {:error, :not_found}
      {:ok, id} -> check_category(id)
    end
  end

  defp check_category(id) do
    query =
      from(c in EquipmentCategory,
        where: c.id == ^id,
        select: %{archived_at: c.archived_at},
        lock: "FOR SHARE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %{archived_at: nil} -> {:ok, id}
      %{archived_at: _archived} -> {:error, :archived_category}
    end
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

  defp normalize_notes(nil), do: nil

  defp normalize_notes(notes) when is_binary(notes) do
    case String.trim(notes) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_notes(_notes), do: nil

  # ── Result translation ──────────────────────────────────────────

  defp unwrap({:ok, %Item{} = item}), do: {:ok, item}
  defp unwrap({:error, {:invalid_values, errors}}), do: {:error, :invalid_values, errors}
  defp unwrap({:error, reason}), do: {:error, reason}
end
