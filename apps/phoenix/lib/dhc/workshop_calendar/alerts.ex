defmodule Dhc.WorkshopCalendar.Alerts do
  @moduledoc "Durable Calendar failure episodes are reported to Sentry once."
  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.WorkshopCalendar.{Event, Recipient, Store}

  @doc "Reports an unalerted terminal event failure after its marker commits."
  @spec deliver(Event.t()) :: :ok | {:error, :calendar_alert_delivery_inside_transaction}
  def deliver(event) do
    if Repo.in_transaction?() do
      {:error, :calendar_alert_delivery_inside_transaction}
    else
      {:ok, report} =
        Repo.transaction(fn ->
          current = Repo.one!(from(e in Event, where: e.id == ^event.id, lock: "FOR UPDATE"))
          mark_event_reported(current)
        end)

      capture(report)
      :ok
    end
  end

  @doc "Reports an unalerted terminal recipient failure after its marker commits."
  @spec deliver_recipient(Event.t(), Recipient.t()) ::
          :ok | {:error, :calendar_alert_delivery_inside_transaction}
  def deliver_recipient(event, recipient) do
    if Repo.in_transaction?() do
      {:error, :calendar_alert_delivery_inside_transaction}
    else
      {:ok, report} =
        Repo.transaction(fn ->
          # The same event → recipient order as source writes and acknowledgments.
          current = Repo.one!(from(e in Event, where: e.id == ^event.id, lock: "FOR UPDATE"))
          row = Repo.one!(from(r in Recipient, where: r.id == ^recipient.id, lock: "FOR UPDATE"))

          mark_recipient_reported(current, row)
        end)

      capture(report)
      :ok
    end
  end

  defp mark_event_reported(%{alerted_at: nil, failure_episode: episode} = event)
       when not is_nil(episode) do
    Store.persist(event, %{alerted_at: DateTime.utc_now()})
    event_report(event, episode)
  end

  defp mark_event_reported(_event), do: nil

  defp mark_recipient_reported(event, recipient) do
    if (recipient.active and recipient.failure_episode) && is_nil(recipient.alerted_at) do
      recipient |> Ecto.Changeset.change(alerted_at: DateTime.utc_now()) |> Repo.update!()
      recipient_report(event, recipient)
    end
  end

  defp event_report(event, episode),
    do:
      {"Workshop Calendar synchronization failed",
       %{
         source_kind: event.source_kind,
         source_id: event.source_id,
         event_id: event.id,
         audience: event.audience,
         reason: event.failure,
         failure_episode: episode
       }}

  defp recipient_report(event, recipient),
    do:
      {"Workshop Calendar recipient synchronization failed",
       %{
         source_kind: event.source_kind,
         source_id: event.source_id,
         event_id: event.id,
         audience: event.audience,
         recipient_id: recipient.id,
         place_id: recipient.place_id,
         reason: recipient.failure,
         failure_episode: recipient.failure_episode
       }}

  defp capture(nil), do: :ok

  defp capture({message, extra}),
    do: Sentry.capture_message(message, level: :error, extra: extra)
end
