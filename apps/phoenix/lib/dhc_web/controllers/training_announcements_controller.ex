defmodule DhcWeb.TrainingAnnouncementsController do
  use DhcWeb, :controller

  action_fallback DhcWeb.TrainingAnnouncementHTTP

  alias Dhc.TrainingAnnouncements
  alias DhcWeb.TrainingAnnouncementHTTP

  def index(conn, params) do
    case Map.get(params, "includeRetired", "false") do
      value when value in ["true", "false"] ->
        TrainingAnnouncements.list(TrainingAnnouncementHTTP.actor_id(conn),
          include_retired: value == "true"
        )
        |> TrainingAnnouncementHTTP.respond(conn, :index)

      _ ->
        TrainingAnnouncementHTTP.respond(
          {:error, ["includeRetired must be true or false"]},
          conn,
          :index
        )
    end
  end

  def show(conn, %{"id" => id}) do
    TrainingAnnouncements.get(TrainingAnnouncementHTTP.actor_id(conn), id)
    |> TrainingAnnouncementHTTP.respond(conn, :show)
  end

  def create(conn, params) do
    with {:ok, attrs} <- TrainingAnnouncementHTTP.copy_attrs(params) do
      TrainingAnnouncements.create(TrainingAnnouncementHTTP.actor_id(conn), attrs)
    end
    |> TrainingAnnouncementHTTP.respond(conn, :schedule, :created)
  end

  def update_schedule(conn, %{"id" => id} = params) do
    TrainingAnnouncements.update_schedule(
      TrainingAnnouncementHTTP.actor_id(conn),
      id,
      TrainingAnnouncementHTTP.attrs(params)
    )
    |> TrainingAnnouncementHTTP.respond(conn, :schedule)
  end

  def update_copy(conn, %{"id" => id} = params) do
    with {:ok, attrs} <- TrainingAnnouncementHTTP.copy_attrs(params) do
      TrainingAnnouncements.update_copy(TrainingAnnouncementHTTP.actor_id(conn), id, attrs)
    end
    |> TrainingAnnouncementHTTP.respond(conn, :show)
  end

  def preview_copy(conn, params) do
    with {:ok, attrs} <- TrainingAnnouncementHTTP.copy_attrs(params) do
      TrainingAnnouncements.preview_copy(TrainingAnnouncementHTTP.actor_id(conn), attrs)
    end
    |> TrainingAnnouncementHTTP.respond(conn, :preview)
  end

  def disable(conn, %{"id" => id}) do
    TrainingAnnouncements.disable(TrainingAnnouncementHTTP.actor_id(conn), id)
    |> TrainingAnnouncementHTTP.respond(conn, :show)
  end

  def enable(conn, %{"id" => id}) do
    TrainingAnnouncements.enable(TrainingAnnouncementHTTP.actor_id(conn), id)
    |> TrainingAnnouncementHTTP.respond(conn, :show)
  end

  def retire(conn, %{"id" => id}) do
    TrainingAnnouncements.retire(TrainingAnnouncementHTTP.actor_id(conn), id)
    |> TrainingAnnouncementHTTP.respond(conn, :show)
  end

  def delete(conn, %{"id" => id}) do
    TrainingAnnouncements.delete(TrainingAnnouncementHTTP.actor_id(conn), id)
    |> TrainingAnnouncementHTTP.respond(conn, :deleted)
  end
end
