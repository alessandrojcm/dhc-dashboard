defmodule Dhc.WorkshopCalendar.Roster do
  @moduledoc """
  Participant-array reconciliation within the shared organizer-event protocol.

  Remove first, then add one entitlement at a time: a rejected address cannot
  strand another person's cancellation or poison every valid addition. Surviving
  Google attendee records (including RSVP) are never reconstructed. An accepted
  entitlement missing from the organizer copy is not invited again in the same
  event generation. A new place has its own entitlement.
  """
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Google, Recipients}

  @content ~w(id summary location start end status visibility guestsCanInviteOthers guestsCanModify guestsCanSeeOtherGuests)
  @meaningful ~w(summary location start end)

  def validate_recipients(event) do
    event
    |> Recipients.list()
    |> Enum.filter(&(&1.active and is_nil(&1.failure)))
    |> Enum.each(fn recipient ->
      unless Recipients.valid?(recipient.recipient),
        do: Recipients.reject(event, recipient, :invalid_recipient)
    end)

    Recipients.alert_failures(event)
  end

  def required?(event, source) do
    Enum.any?(Recipients.list(event), &eligible?(&1, source))
  end

  def reconcile(event, source, observed, desired, clock, allowed) do
    if observed["attendeesOmitted"] == true do
      {:error, :transient}
    else
      recipients = Recipients.list(event)
      attendees = Map.get(observed, "attendees", [])

      with :ok <- Recipients.observed(event, attendees),
           {:ok, current} <-
             remove_and_repair(event, source, observed, desired, recipients, clock, allowed),
           :ok <- Recipients.observed(event, Map.get(current, "attendees", [])),
           {:ok, current} <- add_each(event, source, current, recipients, clock, allowed),
           :ok <- Recipients.observed(event, Map.get(current, "attendees", [])) do
        Recipients.alert_failures(event)
        # Attendee PII belongs only in retained bindings, not a second JSON copy.
        {:ok, Map.take(current, @content)}
      end
    end
  end

  defp remove_and_repair(event, source, observed, desired, recipients, clock, allowed) do
    wanted =
      recipients
      |> Enum.filter(&eligible?(&1, source))
      |> MapSet.new(&Recipients.address(&1.recipient))

    attendees = Map.get(observed, "attendees", [])

    retiring = retiring_addresses(event, source, recipients)

    survivors =
      Enum.filter(attendees, fn attendee ->
        address = Recipients.address(attendee["email"])
        MapSet.member?(wanted, address) and not MapSet.member?(retiring, address)
      end)

    past? = WorkshopCalendar.ended?(source, clock)

    # Historical details stay as recorded. Only owed attendee removals run.
    body = if past?, do: Map.take(observed, @content), else: Map.delete(desired, "attendees")
    body = Map.put(body, "attendees", survivors)

    body =
      if not past? and observed["description"] not in [nil, ""],
        do: Map.put(body, "description", ""),
        else: body

    if matches?(observed, body) do
      {:ok, observed}
    else
      notify? =
        attendees != survivors or Enum.any?(@meaningful, &(not same?(&1, observed[&1], body[&1])))

      write(event, observed, body, allowed, if(notify?, do: "all", else: "none"))
    end
  end

  defp retiring_addresses(event, source, recipients) do
    retiring =
      recipients
      |> Enum.filter(&(not &1.active and &1.removed_generation != event.generation))
      |> MapSet.new(&Recipients.address(&1.recipient))

    retiring =
      Enum.reduce(recipients, retiring, fn r, acc ->
        Enum.reduce(r.previous_recipients, acc, &MapSet.put(&2, Recipients.address(&1)))
      end)

    # A Google guest is shared when multiple logical places use one address.
    # Removing one entitlement must not reset the surviving place's RSVP.
    retained =
      recipients
      |> Enum.filter(
        &(eligible?(&1, source) and is_nil(&1.failure) and
            (&1.invited_generation == event.generation or
               &1.requested_generation == event.generation))
      )
      |> MapSet.new(&Recipients.address(&1.recipient))

    MapSet.difference(retiring, retained)
  end

  defp add_each(event, source, observed, recipients, clock, allowed) do
    Enum.reduce_while(recipients, {:ok, observed}, fn recipient, {:ok, current} ->
      case add_one(event, source, current, recipient, clock, allowed) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        other -> {:halt, other}
      end
    end)
  end

  defp add_one(event, source, current, recipient, clock, allowed) do
    if add?(recipient, source, current, event, clock) do
      invite_or_share(event, source, current, recipient, clock, allowed)
    else
      {:ok, current}
    end
  end

  defp invite_or_share(event, source, current, recipient, clock, allowed) do
    if Enum.any?(
         Map.get(current, "attendees", []),
         &(Recipients.address(&1["email"]) == Recipients.address(recipient.recipient))
       ) do
      # The second place shares an already-present organizer guest. Record
      # its entitlement without notifying or reconstructing that guest.
      with :ok <- allowed.(), :ok <- Recipients.prepare_add(event, recipient), do: {:ok, current}
    else
      body =
        current
        |> Map.take(@content)
        |> Map.put(
          "attendees",
          Map.get(current, "attendees", []) ++ [%{"email" => recipient.recipient}]
        )

      can_add = fn -> prepare_add_before_end(event, source, recipient, clock, allowed) end
      addition_result(write(event, current, body, can_add, "all"), event, recipient, current)
    end
  end

  defp prepare_add_before_end(event, source, recipient, clock, allowed) do
    if WorkshopCalendar.ended?(source, clock) do
      {:skip, :ended}
    else
      with :ok <- allowed.(), do: Recipients.prepare_add(event, recipient)
    end
  end

  defp addition_result({:error, :rejected}, event, recipient, current) do
    with :ok <- Recipients.reject(event, recipient, :rejected_recipient), do: {:ok, current}
  end

  defp addition_result(result, _event, _recipient, _current), do: result

  defp add?(recipient, source, _observed, event, clock) do
    eligible?(recipient, source) and is_nil(recipient.failure) and
      recipient.invited_generation != event.generation and
      not WorkshopCalendar.ended?(source, clock)
  end

  defp eligible?(recipient, source),
    do:
      recipient.active and recipient.place_id in source.place_ids and
        Recipients.valid?(recipient.recipient)

  defp write(event, observed, body, allowed, updates) do
    with :ok <- allowed.(),
         etag when is_binary(etag) <- observed["etag"] do
      Google.update(event.calendar_id, event.event_id, body, etag,
        audience: :participant,
        send_updates: updates,
        before_mutation: allowed
      )
    else
      nil -> {:error, :transient}
      other -> other
    end
  end

  defp matches?(observed, desired),
    do: Enum.all?(desired, fn {key, value} -> same?(key, observed[key], value) end)

  defp same?(key, observed, desired) when key in ["start", "end"] do
    with %{"dateTime" => actual} <- observed,
         %{"dateTime" => expected} <- desired,
         {:ok, actual, _} <- DateTime.from_iso8601(actual),
         {:ok, expected, _} <- DateTime.from_iso8601(expected) do
      DateTime.compare(actual, expected) == :eq and observed["timeZone"] == desired["timeZone"]
    else
      _ -> false
    end
  end

  defp same?(_key, nil, []), do: true
  defp same?(_key, observed, desired), do: observed == desired
end
