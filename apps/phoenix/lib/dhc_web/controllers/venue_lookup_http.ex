defmodule DhcWeb.VenueLookupHTTP do
  @moduledoc """
  The problem fallback for the Google venue lookup (ALE-442). Every refusal
  is a closed reason worded so staff know they can still enter the
  destination by hand; no provider body, key or query is echoed.
  """

  use DhcWeb.Problem,
    reasons: %{
      invalid_query: {422, "Search for a venue name or address of up to 120 characters"},
      invalid_session: {422, "Start the venue search again"},
      invalid_place: {422, "Choose a place from the suggestions"},
      not_found:
        {404,
         "That place is no longer available on Google Maps; search again or enter it manually"},
      not_configured:
        {503, "Google venue search isn't set up; enter the destination details manually"},
      quota_exceeded:
        {503,
         "Google venue search has reached its limit for now; enter the destination details manually"},
      unauthorized:
        {502, "Google venue search isn't authorised; enter the destination details manually"},
      unavailable:
        {502,
         "Google venue search is unavailable right now; enter the destination details manually"}
    }
end
