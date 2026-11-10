defmodule DhcWeb.VenueLookupJSON do
  @moduledoc """
  The closed venue lookup bodies (ALE-442): ordered `{placeId, text}`
  suggestions and a `{provider, placeId, name, address, attributions}`
  preview. Never a provider response.
  """

  alias DhcWeb.DestinationJSON

  def suggestions(%{suggestions: suggestions}) do
    %{
      data: %{
        suggestions: for(s <- suggestions, do: %{placeId: s.place_id, text: s.text})
      }
    }
  end

  def selection(%{selection: selection}) do
    %{
      data: %{
        provider: selection.provider,
        placeId: selection.place_id,
        name: selection.name,
        address: selection.address,
        attributions: DestinationJSON.attributions(selection.attributions)
      }
    }
  end
end
