defmodule DhcWeb.VenueLookupJSON do
  @moduledoc """
  The closed venue lookup bodies (ALE-442): ordered `{placeId, text}`
  suggestions and a `{provider, placeId, name, address, attributions}`
  preview. Never a provider response. The preview is shown only while
  staff edit a destination; no part of it but the Place ID is ever saved.
  """

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
        attributions:
          for(
            credit <- selection.attributions,
            do: %{provider: credit["provider"], providerUri: credit["provider_uri"]}
          )
      }
    }
  end
end
