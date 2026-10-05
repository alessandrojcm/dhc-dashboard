defmodule DhcWeb.TrainingAnnouncementOccurrencesController do
  use DhcWeb, :controller
  alias Dhc.TrainingAnnouncements
  alias DhcWeb.TrainingAnnouncementHTTP, as: HTTP

  def window(conn, params) do
    TrainingAnnouncements.occurrence_window(HTTP.actor_id(conn), params["from"], params["to"])
    |> HTTP.respond(conn, :index)
  end

  def show(conn, %{"id" => id, "date" => date}) do
    TrainingAnnouncements.get_occurrence(HTTP.actor_id(conn), id, date)
    |> HTTP.respond(conn, :show)
  end

  def list_for_announcement(conn, %{"id" => id} = params) do
    TrainingAnnouncements.list_occurrences(
      HTTP.actor_id(conn),
      id,
      Map.take(params, ["direction", "limit"])
    )
    |> HTTP.respond(conn, :index)
  end
end
