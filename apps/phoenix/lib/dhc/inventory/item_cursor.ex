defmodule Dhc.Inventory.ItemCursor do
  @moduledoc false

  alias Dhc.Inventory.Item

  @spec parse(String.t() | nil, map()) :: {:ok, map() | nil} | {:error, :bad_cursor}
  def parse(nil, _opts), do: {:ok, nil}

  def parse(cursor, opts) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, decoded} <- Jason.decode(json),
         %{"createdAt" => created_at, "id" => id, "filters" => filters} <- decoded,
         true <- filters == filters(opts) do
      with {:ok, dt, _} <- DateTime.from_iso8601(created_at) do
        {:ok, %{created_at: dt, id: id}}
      else
        _ -> {:error, :bad_cursor}
      end
    else
      _ -> {:error, :bad_cursor}
    end
  end

  @spec next([Item.t()], [Item.t()], map()) :: String.t() | nil
  def next(visible, rows, opts) do
    if length(rows) <= opts.limit do
      nil
    else
      %Item{} = last = List.last(visible)
      encode(last, opts)
    end
  end

  defp encode(%Item{} = item, opts) do
    Jason.encode!(%{
      "createdAt" => serialize_dt(item.created_at),
      "id" => item.id,
      "filters" => filters(opts)
    })
    |> Base.url_encode64(padding: false)
  end

  defp filters(opts) do
    %{
      "limit" => opts.limit,
      "categoryId" => opts.category_id,
      "containerId" => opts.container_id,
      "outForMaintenance" => opts.out_for_maintenance,
      "search" => opts.search
    }
  end

  defp serialize_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_dt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
