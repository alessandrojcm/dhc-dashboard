defmodule Dhc.GoogleCalendarAuthConfig do
  @moduledoc "Synthetic shared connection routed through the caller's Req.Test HTTP surface."

  def configure!(http_name) do
    previous = Application.get_env(:dhc, Dhc.GoogleCalendar.Auth)

    Application.put_env(:dhc, Dhc.GoogleCalendar.Auth,
      client_id: "organizer-client",
      client_secret: "organizer-secret",
      refresh_token: "organizer-refresh-token",
      req_options: [plug: {Req.Test, http_name}]
    )

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:dhc, Dhc.GoogleCalendar.Auth, previous),
        else: Application.delete_env(:dhc, Dhc.GoogleCalendar.Auth)
    end)
  end

  def token(value) do
    %{
      "access_token" => value,
      "scope" =>
        "https://www.googleapis.com/auth/calendar.events.owned https://www.googleapis.com/auth/calendar.acls"
    }
  end
end
