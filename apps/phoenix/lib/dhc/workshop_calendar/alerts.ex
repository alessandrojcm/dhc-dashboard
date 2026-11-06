defmodule Dhc.WorkshopCalendar.Alerts do
  @moduledoc "Durable failure episodes outlive Notification retention; signaling follows commit."
  import Ecto.Query

  alias Dhc.Auth.Capabilities
  alias Dhc.BeginnersWorkshops
  alias Dhc.Notifications
  alias Dhc.Repo
  alias Dhc.WorkshopCalendar.{Event, Store}

  def deliver(event) do
    {:ok, created} =
      Repo.transaction(fn ->
        current = Repo.one!(from(e in Event, where: e.id == ^event.id, lock: "FOR UPDATE"))
        deliver_unalerted(current)
      end)

    Enum.each(created, &Notifications.signal_created/1)
    :ok
  end

  defp deliver_unalerted(%{alerted_at: nil, failure_episode: episode} = event)
       when not is_nil(episode) do
    created =
      capability(event)
      |> Capabilities.principal_ids_with()
      |> Enum.flat_map(fn id ->
        case Notifications.create_keyed_in_transaction(
               id,
               "workshop-calendar:#{event.id}:#{episode}",
               copy(event)
             ) do
          {:ok, :created, notification} -> [notification]
          {:ok, :already_created} -> []
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    Store.persist(event, %{alerted_at: DateTime.utc_now()})
    created
  end

  defp deliver_unalerted(_event), do: []

  defp capability(%{source_kind: "workshop"}), do: :"workshops.manage"
  defp capability(%{source_kind: "beginners_workshop"}), do: :"beginners.workshops.alerts.receive"

  defp copy(%{source_kind: "beginners_workshop"} = event),
    do: BeginnersWorkshops.calendar_failure_copy(event.source_id, event.failure)

  defp copy(event) do
    reason =
      case event.failure do
        "unauthorized" -> "Organizer authorization needs renewal."
        "configuration" -> "Check organizer ownership and the two calendar IDs."
        "rejected" -> "Google refused the event. Check the workshop details."
        _ -> "Automatic retries are exhausted. Check Google availability and configuration."
      end

    "Workshop Calendar needs attention for workshop #{event.source_id}. #{reason} Bookings are unchanged."
  end
end
