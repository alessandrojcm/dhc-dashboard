defmodule DhcWeb.DestinationJSON do
  @moduledoc """
  The public shape of a selected destination's provider credits (ALE-442),
  shared by every workshop read that carries `destinationAttributions`.

  Stored credits are `%{"provider" => name, "provider_uri" => url | nil}`
  (`Dhc.Destinations.normalize_attributions/1`); the wire uses the closed
  `{provider, providerUri}` shape, never a provider response.
  """

  @doc "The stored credits as `[%{provider:, providerUri:}]` (empty when none)."
  @spec attributions([map()] | nil) :: [%{provider: String.t(), providerUri: String.t() | nil}]
  def attributions(nil), do: []

  def attributions(list) when is_list(list) do
    for item <- list,
        do: %{provider: item["provider"], providerUri: item["provider_uri"]}
  end
end
