defmodule DhcWeb.VenueLookupController do
  @moduledoc """
  The Google venue lookup (ALE-442): search suggestions and the closed
  preview of a chosen one, through `Dhc.Places`. It writes nothing — a
  selection is saved by each Workshop domain's own form — and every answer
  is `Cache-Control: no-store`, so no suggestion or preview is cached.
  """

  use DhcWeb, :controller

  alias Dhc.Places

  action_fallback DhcWeb.VenueLookupHTTP

  @doc "POST /venue-lookup/suggestions"
  def suggest(conn, params) do
    with {:ok, suggestions} <- Places.suggest(params["input"], params["sessionToken"]) do
      conn
      |> no_store()
      |> render(:suggestions, suggestions: suggestions)
    end
  end

  @doc "POST /venue-lookup/selections"
  def resolve(conn, params) do
    with {:ok, selection} <- Places.resolve(params["placeId"], params["sessionToken"]) do
      conn
      |> no_store()
      |> render(:selection, selection: selection)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
