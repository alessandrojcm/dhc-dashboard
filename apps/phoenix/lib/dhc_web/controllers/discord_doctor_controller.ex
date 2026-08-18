defmodule DhcWeb.DiscordDoctorController do
  use DhcWeb, :controller

  alias Dhc.Discord

  def report(conn, params) do
    case Discord.doctor_report(refresh: params["refresh"] == "true") do
      {:ok, report} ->
        render(conn, :report, report: report)

      {:error, _reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{errors: %{detail: "Discord member list unavailable"}})
    end
  end
end
