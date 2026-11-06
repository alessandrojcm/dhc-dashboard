defmodule Dhc.WorkshopCalendar.Recipients do
  @moduledoc "Retained confirmation entitlements, not a live profile address lookup."
  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.WorkshopCalendar.{Alerts, Control, Event, Recipient, Store}

  def confirm(kind, id, place_id, recipient) do
    require_transaction!()
    Store.ensure(kind, id, "participant")
    event = lock_event(kind, id)
    now = DateTime.utc_now()

    {count, _} =
      Repo.insert_all(
        Recipient,
        [
          %{
            id: Ecto.UUID.generate(),
            event_id: event.id,
            place_id: place_id,
            recipient: recipient,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:event_id, :place_id],
        log: false
      )

    if count == 1, do: changed(event)
    :ok
  end

  def remove(kind, id, place_id) do
    require_transaction!()

    if event = lock_event(kind, id) do
      {count, _} =
        from(r in Recipient,
          where: r.event_id == ^event.id and r.place_id == ^place_id and r.active
        )
        |> Repo.update_all(set: [active: false, updated_at: DateTime.utc_now()])

      if count > 0, do: changed(event)
    end

    :ok
  end

  def list(event),
    do: Repo.all(from(r in Recipient, where: r.event_id == ^event.id, order_by: r.id))

  def correct(kind, id, place_id, recipient) do
    {:ok, result} =
      Repo.transaction(fn ->
        control = Repo.one!(from(c in Control, where: c.id == 1, lock: "FOR SHARE"))
        event = lock_event(kind, id)
        correct_locked(control, event, place_id, recipient)
      end)

    result
  end

  defp correct_locked(%{paused: false}, _event, _place, _recipient), do: {:error, :pause_required}
  defp correct_locked(_control, nil, _place, _recipient), do: {:error, :not_found}

  defp correct_locked(_control, event, place_id, recipient) do
    row = Repo.get_by(Recipient, event_id: event.id, place_id: place_id, active: true)

    cond do
      not valid?(recipient) ->
        {:error, :invalid_recipient}

      event.lease_until && DateTime.compare(event.lease_until, DateTime.utc_now()) == :gt ->
        {:error, :busy}

      is_nil(row) ->
        {:error, :not_found}

      row.recipient == recipient ->
        :ok

      true ->
        replace_recipient(event, row, recipient)
    end
  end

  defp replace_recipient(event, row, recipient) do
    previous =
      [row.recipient | row.previous_recipients]
      |> Enum.reject(&(is_nil(&1) or address(&1) == address(recipient)))
      |> Enum.uniq()

    row
    |> Ecto.Changeset.change(
      recipient: recipient,
      previous_recipients: previous,
      requested_generation: nil,
      invited_generation: nil,
      failure: nil,
      failure_episode: nil,
      alerted_at: nil
    )
    |> Repo.update!(log: false)

    changed(event)
    :ok
  end

  def observed(event, attendees) do
    emails = MapSet.new(attendees, &address(&1["email"]))

    Store.owned(event, fn current ->
      if current.revision == event.revision do
        {ids, removed} = observed_ids(current, emails)

        from(r in Recipient, where: r.id in ^ids)
        |> Repo.update_all(set: [invited_generation: event.generation])

        from(r in Recipient, where: r.id in ^removed)
        |> Repo.update_all(set: [removed_generation: event.generation])

        :ok
      else
        {:skip, :changed}
      end
    end)
  end

  defp observed_ids(event, emails) do
    recipients = list(event)

    invited =
      for r <- recipients,
          r.active and r.requested_generation == event.generation and
            MapSet.member?(emails, address(r.recipient)),
          do: r.id

    removed =
      for r <- recipients,
          not r.active and not MapSet.member?(emails, address(r.recipient)),
          do: r.id

    {invited, removed}
  end

  def prepare_add(event, recipient) do
    Store.owned(event, fn current ->
      if current.revision == event.revision do
        from(r in Recipient, where: r.id == ^recipient.id and r.active)
        |> Repo.update_all(set: [requested_generation: event.generation])

        :ok
      else
        {:skip, :changed}
      end
    end)
  end

  def reject(event, recipient, reason) do
    Store.owned(event, fn current ->
      if current.revision == event.revision do
        row = Repo.get!(Recipient, recipient.id)

        row
        |> Ecto.Changeset.change(
          failure: to_string(reason),
          failure_episode: row.failure_episode || Ecto.UUID.generate()
        )
        |> Repo.update!()

        :ok
      else
        {:skip, :changed}
      end
    end)
  end

  def alert_failures(event) do
    event
    |> list()
    |> Enum.filter(&(&1.active and not is_nil(&1.failure) and is_nil(&1.alerted_at)))
    |> Enum.each(&Alerts.deliver_recipient(event, &1))
  end

  def valid?(recipient) when is_binary(recipient),
    do:
      byte_size(recipient) <= 254 and
        Regex.match?(~r/^[^\s@<>(),;:"\\]+@[^\s@<>(),;:"\\]+\.[^\s@<>(),;:"\\]+$/u, recipient)

  def valid?(_), do: false

  def address(nil), do: ""
  def address(value), do: String.downcase(value)

  defp lock_event(kind, id) do
    Repo.one(
      from(e in Event,
        where:
          e.source_kind == ^to_string(kind) and e.source_id == ^id and e.audience == "participant",
        lock: "FOR UPDATE"
      )
    )
  end

  defp changed(event) do
    Store.persist(event, %{revision: event.revision + 1, removal_completed: false})
    Store.enqueue_audience(event.source_kind, event.source_id, "participant")
  end

  defp require_transaction! do
    unless Repo.in_transaction?(), do: raise("Calendar recipients require the source transaction")
  end
end
