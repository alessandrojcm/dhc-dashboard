defmodule Dhc.WorkshopCalendar.Sync do
  @moduledoc """
  One desired-versus-observed organizer-event protocol.

  Persisted event IDs make uncertain inserts readable on retry. Replacements
  of tombstoned IDs advance a durable generation first. ETags fence updates
  and deletions against Google-side changes; the local lease/revision fences
  acknowledgments against concurrent drivers and source transactions.
  """
  alias Dhc.BeginnersWorkshops
  alias Dhc.ClubCalendar
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Alerts, Google, Store}
  alias Dhc.Workshops

  def run(%{deleted: true, create_requested: false, acknowledged: nil} = event, clock) do
    # No request was ever prepared for this identity. Ownership fencing stops
    # an old driver from preparing one after this deletion is acknowledged.
    finish(event, nil, projection(event), clock, removed: true)
  end

  def run(event, clock) do
    result =
      with :ok <- validate_configuration(),
           false <- Store.exhausted?(event),
           {:ok, bound} <- Store.bind_calendar(event, calendar_id()) do
        reconcile(bound, clock)
      else
        true -> {:error, :exhausted}
        other -> other
      end

    conclude(event, result, clock)
  end

  defp reconcile(event, clock) do
    source = projection(event)

    with :ok <- valid_schedule(source) do
      observe(event, source, clock)
    end
  end

  defp observe(event, source, clock) do
    case Google.get(event.calendar_id, event.event_id) do
      {:ok, %{"status" => "cancelled"}} ->
        absent(event, source, :gone, clock)

      {:ok, observed} ->
        present(event, source, observed, clock)

      {:error, reason} when reason in [:missing, :gone] ->
        confirmed_absence(event, source, reason, clock)

      error ->
        error
    end
  end

  defp confirmed_absence(event, source, reason, clock) do
    with :ok <- Google.check_calendar(event.calendar_id) do
      absent(event, source, reason, clock)
    end
  end

  defp absent(event, source, reason, clock) do
    cond do
      event.deleted or is_nil(source) ->
        # A 404 is not a tombstone: an earlier timed-out insert may still
        # arrive. Keep absence-only removals in repair until Google has a
        # tombstone (or a successful conditional delete) for this identity.
        finish(event, nil, source, clock, removed: reason == :gone or not event.create_requested)

      ended?(source, clock) ->
        finish(event, event.acknowledged, source, clock)

      reason == :gone or not is_nil(event.acknowledged) ->
        with {:ok, next} <- Store.next_generation(event) do
          # Keep the new ownership identity through failure/release as well.
          conclude(next, create(next, source, clock), clock)
        end

      true ->
        create(event, source, clock)
    end
  end

  defp create(event, source, clock) do
    desired = desired_event(event, source)

    with :ok <- mutation_allowed(event, source, clock) do
      case Google.insert(event.calendar_id, desired,
             before_mutation: fn ->
               with :ok <- mutation_allowed(event, source, clock), do: Store.prepare_create(event)
             end
           ) do
        {:ok, _observed} -> finish(event, desired, source, clock)
        {:error, :conflict} -> recover_conflicting_insert(event, source, clock)
        other -> other
      end
    end
  end

  defp recover_conflicting_insert(event, source, clock) do
    case Google.get(event.calendar_id, event.event_id) do
      {:ok, %{"status" => "cancelled"}} -> defer_new_generation(event, clock)
      {:ok, observed} -> present(event, source, observed, clock)
      {:error, reason} when reason in [:gone, :missing] -> defer_new_generation(event, clock)
      other -> other
    end
  end

  defp defer_new_generation(event, clock) do
    with {:ok, next} <- Store.next_generation(event) do
      conclude(next, {:error, :conflict}, clock)
    end
  end

  defp present(event, source, observed, clock) do
    cond do
      event.deleted or is_nil(source) ->
        remove(event, source, observed, clock)

      ended?(source, clock) and source.status != "cancelled" ->
        finish(event, event.acknowledged, source, clock)

      true ->
        update_if_changed(event, source, observed, clock)
    end
  end

  defp update_if_changed(event, source, observed, clock) do
    desired = desired_event(event, source)

    if matches?(observed, desired) do
      finish(event, desired, source, clock)
    else
      body =
        if Map.get(observed, "attendees", []) == [] and
             not Map.get(observed, "attendeesOmitted", false),
           do: desired,
           else: Map.put(desired, "attendees", [])

      with :ok <- mutation_allowed(event, source, clock),
           {:ok, etag} <- etag(observed),
           {:ok, _updated} <-
             Google.update(event.calendar_id, event.event_id, body, etag,
               before_mutation: fn -> mutation_allowed(event, source, clock) end
             ) do
        finish(event, desired, source, clock)
      end
    end
  end

  defp remove(event, source, observed, clock) do
    with :ok <- mutation_allowed(event, source, clock),
         {:ok, etag} <- etag(observed) do
      case Google.delete(event.calendar_id, event.event_id, etag,
             before_mutation: fn -> mutation_allowed(event, source, clock) end
           ) do
        {:ok, _deleted} ->
          finish(event, nil, source, clock, removed: true)

        {:error, reason} when reason in [:missing, :gone] ->
          confirmed_absence(event, source, reason, clock)

        error ->
          error
      end
    end
  end

  defp matches?(observed, desired) do
    Map.get(observed, "attendees", []) == [] and not Map.get(observed, "attendeesOmitted", false) and
      Enum.all?(desired, fn {key, value} -> same_field?(key, observed[key], value) end)
  end

  defp same_field?(key, observed, desired) when key in ["start", "end"] do
    with %{"dateTime" => actual} <- observed,
         {:ok, actual, _offset} <- DateTime.from_iso8601(actual),
         {:ok, expected, _offset} <- DateTime.from_iso8601(desired["dateTime"]) do
      DateTime.compare(actual, expected) == :eq and observed["timeZone"] == desired["timeZone"]
    else
      _ -> false
    end
  end

  defp same_field?(_key, observed, desired), do: observed == desired

  defp desired_event(event, source) do
    %{
      "id" => event.event_id,
      "summary" => summary(source),
      "description" => dashboard_link(event.source_kind, source.id),
      "location" => source.location,
      "start" => %{
        "dateTime" => DateTime.to_iso8601(source.start_date),
        "timeZone" => ClubCalendar.zone()
      },
      "end" => %{
        "dateTime" => DateTime.to_iso8601(source.end_date),
        "timeZone" => ClubCalendar.zone()
      },
      "status" => "confirmed",
      "visibility" => "default",
      "guestsCanInviteOthers" => false,
      "guestsCanModify" => false,
      "guestsCanSeeOtherGuests" => false
    }
  end

  defp summary(%{status: "planned", title: title}), do: "[Planned] " <> title
  defp summary(%{status: "cancelled", title: title}), do: "[Cancelled] " <> title
  defp summary(%{title: title}), do: title

  defp dashboard_link(kind, id) do
    String.trim_trailing(Application.fetch_env!(:dhc, :app_url), "/") <>
      dashboard_path(kind, id)
  end

  defp dashboard_path("workshop", id), do: "/dashboard/workshops/#{id}/attendees"

  defp dashboard_path("beginners_workshop", id),
    do: "/dashboard/beginners-workshop/workshops/#{id}"

  defp mutation_allowed(event, source, clock) do
    cond do
      not WorkshopCalendar.outbound?() -> {:skip, :paused}
      source_changed?(event, source) -> {:skip, :changed}
      source && ended?(source, clock) && source.status != "cancelled" -> {:skip, :ended}
      true -> :ok
    end
  end

  defp source_changed?(event, source),
    do: projection(event) != source

  defp projection(%{source_kind: "workshop", source_id: id}),
    do: Workshops.calendar_projection(id)

  defp projection(%{source_kind: "beginners_workshop", source_id: id}),
    do: BeginnersWorkshops.calendar_projection(id)

  defp valid_schedule(nil), do: :ok
  defp valid_schedule(%{end_date: nil}), do: {:error, :missing_end_time}

  defp valid_schedule(%{start_date: %DateTime{} = start_date, end_date: %DateTime{} = end_date}) do
    if DateTime.compare(end_date, start_date) == :gt,
      do: :ok,
      else: {:error, :invalid_schedule}
  end

  defp valid_schedule(_source), do: {:error, :invalid_schedule}

  defp finish(event, desired, source, clock, opts \\ []) do
    Store.finish(
      event,
      desired,
      clock.(),
      Keyword.put(opts, :stale, source_changed?(event, source))
    )
  end

  defp conclude(event, {:error, reason}, clock) do
    case Store.fail(event, reason, clock.()) do
      {:retry, delay} -> {:snooze, delay}
      {:failed, failed} -> Alerts.deliver(failed)
      {:skip, _} -> :ok
    end
  end

  defp conclude(event, {:skip, reason}, _clock) do
    Store.release(event)
    if reason == :changed, do: {:snooze, 1}, else: :ok
  end

  defp conclude(_event, result, _clock), do: result

  defp ended?(source, clock), do: DateTime.compare(clock.(), source.end_date) != :lt

  defp etag(%{"etag" => etag}) when is_binary(etag) and etag != "", do: {:ok, etag}
  defp etag(_observed), do: {:error, :transient}

  defp calendar_id, do: Keyword.get(WorkshopCalendar.config(), :committee_calendar_id)

  defp validate_configuration do
    config = WorkshopCalendar.config()
    committee = Keyword.get(config, :committee_calendar_id)
    participant = Keyword.get(config, :participant_calendar_id)
    origin = URI.new(Application.get_env(:dhc, :app_url, ""))

    if nonempty?(committee) and nonempty?(participant) and committee != participant and
         valid_origin?(origin),
       do: :ok,
       else: {:error, :configuration}
  end

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_origin?(
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
       )
       when scheme in ["http", "https"] and is_binary(host), do: true

  defp valid_origin?(_), do: false
end
