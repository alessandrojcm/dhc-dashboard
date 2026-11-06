defmodule Dhc.WorkshopCalendar.AlertsTest do
  use Dhc.DataCase, async: false

  alias Dhc.Repo
  alias Dhc.WorkshopCalendar.{Alerts, Event, Recipient}

  setup do
    Sentry.Test.setup_sentry()
    :ok
  end

  test "reports a terminal event failure once for its durable episode" do
    event = failed_event!()

    assert :ok = Alerts.deliver(event)

    assert [
             %Sentry.Event{
               message: %{formatted: "Workshop Calendar synchronization failed"},
               extra: extra
             }
           ] =
             Sentry.Test.pop_sentry_reports()

    assert extra == %{
             audience: "committee",
             event_id: event.id,
             failure_episode: event.failure_episode,
             reason: "unauthorized",
             source_id: event.source_id,
             source_kind: "workshop"
           }

    assert Repo.get!(Event, event.id).alerted_at
    assert :ok = Alerts.deliver(Repo.get!(Event, event.id))
    assert [] = Sentry.Test.pop_sentry_reports()
  end

  test "reports a recipient failure without its retained address" do
    event = event!()

    recipient =
      Repo.insert!(%Recipient{
        event_id: event.id,
        place_id: Ecto.UUID.generate(),
        recipient: "private@example.test",
        failure: "rejected_recipient",
        failure_episode: Ecto.UUID.generate()
      })

    assert :ok = Alerts.deliver_recipient(event, recipient)

    assert [
             %Sentry.Event{
               message: %{formatted: "Workshop Calendar recipient synchronization failed"},
               extra: extra
             } = report
           ] =
             Sentry.Test.pop_sentry_reports()

    assert extra == %{
             audience: "participant",
             event_id: event.id,
             failure_episode: recipient.failure_episode,
             place_id: recipient.place_id,
             reason: "rejected_recipient",
             recipient_id: recipient.id,
             source_id: event.source_id,
             source_kind: "beginners_workshop"
           }

    refute inspect(report) =~ "private@example.test"
    assert Repo.get!(Recipient, recipient.id).alerted_at
    assert :ok = Alerts.deliver_recipient(event, Repo.get!(Recipient, recipient.id))
    assert [] = Sentry.Test.pop_sentry_reports()
  end

  test "refuses to report an event failure from an outer transaction that rolls back" do
    event = failed_event!()

    assert {:error, :expected_rollback} =
             Repo.transaction(fn ->
               assert {:error, :calendar_alert_delivery_inside_transaction} =
                        Alerts.deliver(event)

               Repo.rollback(:expected_rollback)
             end)

    assert is_nil(Repo.get!(Event, event.id).alerted_at)
    assert [] = Sentry.Test.pop_sentry_reports()
  end

  test "refuses to report a recipient failure from an outer transaction that rolls back" do
    event = event!()

    recipient =
      Repo.insert!(%Recipient{
        event_id: event.id,
        place_id: Ecto.UUID.generate(),
        recipient: "private@example.test",
        failure: "rejected_recipient",
        failure_episode: Ecto.UUID.generate()
      })

    assert {:error, :expected_rollback} =
             Repo.transaction(fn ->
               assert {:error, :calendar_alert_delivery_inside_transaction} =
                        Alerts.deliver_recipient(event, recipient)

               Repo.rollback(:expected_rollback)
             end)

    assert is_nil(Repo.get!(Recipient, recipient.id).alerted_at)
    assert [] = Sentry.Test.pop_sentry_reports()
  end

  defp failed_event! do
    Repo.insert!(%Event{
      source_kind: "workshop",
      source_id: Ecto.UUID.generate(),
      audience: "committee",
      event_id: "event-id",
      failure: "unauthorized",
      failure_episode: Ecto.UUID.generate()
    })
  end

  defp event! do
    Repo.insert!(%Event{
      source_kind: "beginners_workshop",
      source_id: Ecto.UUID.generate(),
      audience: "participant",
      event_id: "event-id"
    })
  end
end
