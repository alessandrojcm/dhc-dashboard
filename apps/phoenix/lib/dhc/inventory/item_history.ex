defmodule Dhc.Inventory.ItemHistory do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Inventory.Container
  alias Dhc.Inventory.InventoryHistory
  alias Dhc.Inventory.Item
  alias Dhc.Repo

  @type history :: InventoryHistory.t()

  @spec list_item_history(String.t(), keyword() | map()) ::
          {:ok, [history()]} | {:error, :not_found}
  def list_item_history(id, opts \\ %{}) when is_binary(id) do
    case Repo.get(Item, id) do
      nil ->
        {:error, :not_found}

      %Item{} ->
        limit = history_limit(opts)

        rows =
          from(h in InventoryHistory,
            left_join: old in Container,
            on: old.id == h.old_container_id,
            left_join: new in Container,
            on: new.id == h.new_container_id,
            where: h.item_id == ^id,
            order_by: [desc: h.created_at, desc: h.id],
            limit: ^limit,
            select_merge: %{
              old_container:
                fragment(
                  "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?::text, 'name', ?) ELSE NULL END",
                  old.id,
                  old.id,
                  old.name
                ),
              new_container:
                fragment(
                  "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?::text, 'name', ?) ELSE NULL END",
                  new.id,
                  new.id,
                  new.name
                )
            }
          )
          |> Repo.all()

        {:ok, rows}
    end
  end

  @doc false
  def record_created_history(%Item{} = item, actor_id, notes) do
    %InventoryHistory{
      item_id: item.id,
      action: :created,
      old_container_id: nil,
      new_container_id: item.container_id,
      changed_by: actor_id,
      notes: notes,
      created_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:item_id, name: :inventory_history_item_id_fkey)
    |> Ecto.Changeset.foreign_key_constraint(:changed_by,
      name: :inventory_history_changed_by_fkey
    )
  end

  @doc false
  def record_moved_history(item_id, old_container_id, new_container_id, actor_id, notes) do
    %InventoryHistory{
      item_id: item_id,
      action: :moved,
      old_container_id: old_container_id,
      new_container_id: new_container_id,
      changed_by: actor_id,
      notes: notes,
      created_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:item_id, name: :inventory_history_item_id_fkey)
    |> Ecto.Changeset.foreign_key_constraint(:old_container_id,
      name: :inventory_history_old_container_id_fkey
    )
    |> Ecto.Changeset.foreign_key_constraint(:new_container_id,
      name: :inventory_history_new_container_id_fkey
    )
    |> Ecto.Changeset.foreign_key_constraint(:changed_by,
      name: :inventory_history_changed_by_fkey
    )
  end

  @doc false
  def record_updated_history(item_id, actor_id, notes) do
    %InventoryHistory{
      item_id: item_id,
      action: :updated,
      old_container_id: nil,
      new_container_id: nil,
      changed_by: actor_id,
      notes: notes,
      created_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:item_id, name: :inventory_history_item_id_fkey)
    |> Ecto.Changeset.foreign_key_constraint(:changed_by,
      name: :inventory_history_changed_by_fkey
    )
  end

  @doc false
  @spec record_maintenance_history(String.t(), boolean(), String.t(), term()) ::
          Ecto.Changeset.t()
  def record_maintenance_history(item_id, out_for_maintenance, actor_id, notes) do
    action = if(out_for_maintenance, do: :maintenance_out, else: :maintenance_in)

    %InventoryHistory{
      item_id: item_id,
      action: action,
      old_container_id: nil,
      new_container_id: nil,
      changed_by: actor_id,
      notes: notes,
      created_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:item_id, name: :inventory_history_item_id_fkey)
    |> Ecto.Changeset.foreign_key_constraint(:changed_by,
      name: :inventory_history_changed_by_fkey
    )
  end

  @doc """
  Global inventory activity feed — newest `inventory_history` rows across all
  items, newest first, with `old_container`/`new_container` name summaries and
  an `item` summary (`%{id, attributes}`). Used by the dashboard overview.
  """
  @spec list_history(keyword() | map()) ::
          {:ok, [history()]}
  def list_history(opts \\ %{}) do
    limit = global_history_limit(opts)

    rows =
      from(h in InventoryHistory,
        left_join: old in Container,
        on: old.id == h.old_container_id,
        left_join: new in Container,
        on: new.id == h.new_container_id,
        left_join: item in Item,
        on: item.id == h.item_id,
        order_by: [desc: h.created_at, desc: h.id],
        limit: ^limit,
        select_merge: %{
          old_container:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?::text, 'name', ?) ELSE NULL END",
              old.id,
              old.id,
              old.name
            ),
          new_container:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?::text, 'name', ?) ELSE NULL END",
              new.id,
              new.id,
              new.name
            ),
          item:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?::text, 'attributes', ?) ELSE NULL END",
              item.id,
              item.id,
              item.attributes
            )
        }
      )
      |> Repo.all()

    {:ok, rows}
  end

  defp global_history_limit(opts) when is_map(opts) do
    opts
    |> Map.get("limit")
    |> parse_integer(50)
    |> max(1)
    |> min(100)
  end

  defp global_history_limit(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> global_history_limit()
  end

  defp history_limit(opts) when is_map(opts) do
    opts
    |> Map.get("limit")
    |> parse_integer(20)
    |> max(1)
    |> min(100)
  end

  defp history_limit(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> history_limit()
  end

  defp parse_integer(nil, default), do: default
  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end
end
