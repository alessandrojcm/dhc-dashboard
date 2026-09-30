defmodule DhcWeb.TrainingAnnouncementExceptionsController do
  use DhcWeb, :controller

  alias Dhc.TrainingAnnouncements
  alias DhcWeb.TrainingAnnouncementHTTP

  def list_suppressions(conn, %{"id" => id}) do
    TrainingAnnouncements.list_suppressions(TrainingAnnouncementHTTP.actor_id(conn), id)
    |> TrainingAnnouncementHTTP.respond(conn, :suppressions)
  end

  def create_suppression(conn, %{"id" => id} = params) do
    TrainingAnnouncements.suppress(
      TrainingAnnouncementHTTP.actor_id(conn),
      id,
      TrainingAnnouncementHTTP.attrs(params)
    )
    |> TrainingAnnouncementHTTP.respond(conn, :suppression, :created)
  end

  def delete_suppression(conn, %{"id" => id, "exceptionId" => exception_id}) do
    TrainingAnnouncements.remove_suppression(
      TrainingAnnouncementHTTP.actor_id(conn),
      id,
      exception_id
    )
    |> TrainingAnnouncementHTTP.respond(conn, :deleted)
  end

  def list_overrides(conn, %{"id" => id}) do
    TrainingAnnouncements.list_overrides(TrainingAnnouncementHTTP.actor_id(conn), id)
    |> TrainingAnnouncementHTTP.respond(conn, :overrides)
  end

  def create_override(conn, %{"id" => id} = params) do
    TrainingAnnouncements.override(
      TrainingAnnouncementHTTP.actor_id(conn),
      id,
      TrainingAnnouncementHTTP.attrs(params)
    )
    |> TrainingAnnouncementHTTP.respond(conn, :override, :created)
  end

  def delete_override(conn, %{"id" => id, "exceptionId" => exception_id}) do
    TrainingAnnouncements.remove_override(
      TrainingAnnouncementHTTP.actor_id(conn),
      id,
      exception_id
    )
    |> TrainingAnnouncementHTTP.respond(conn, :deleted)
  end
end
