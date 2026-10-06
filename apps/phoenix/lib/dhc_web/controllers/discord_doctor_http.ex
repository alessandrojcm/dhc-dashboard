defmodule DhcWeb.DiscordDoctorHTTP do
  @moduledoc """
  The problem fallback for the Discord Doctor HTTP slice. Kick-request
  validation messages are a message list, rendered as a 422 `detail`.
  """

  use DhcWeb.Problem,
    reasons: %{
      discord_unavailable: {502, "Discord member list unavailable"},
      admin_not_found: {422, "Authenticated administrator profile unavailable"}
    }
end
