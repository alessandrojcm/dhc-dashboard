defmodule DhcWeb.BeginnersWorkshopCarriedFeesController do
  @moduledoc """
  The `beginnersWorkshopCarriedFees` slice (ALE-388): the Carried Fee status
  of the people a Waitlist page lists. `Dhc.Waitlist` (and its web slice)
  never reads Beginners' Workshops, so the dashboard asks here. Gated on
  `beginners.waitlist.manage`, the Waitlist view's own capability.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops

  @max_ids 100

  @doc "GET /beginners-workshops/carried-fees?waitlistIds=a,b"
  def index(conn, params) do
    with {:ok, ids} <- waitlist_ids(Map.get(params, "waitlistIds")) do
      render(conn, :index, carried_fees: BeginnersWorkshops.carried_fees(ids))
    end
  end

  defp waitlist_ids(value) when is_binary(value) do
    ids = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    casted = Enum.map(ids, &Ecto.UUID.cast/1)

    if length(ids) <= @max_ids and Enum.all?(casted, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(casted, fn {:ok, id} -> id end)},
      else: {:error, :invalid_ids}
  end

  defp waitlist_ids(_missing), do: {:error, :invalid_ids}
end
