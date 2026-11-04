defmodule Dhc.WorkshopCalendar.Store do
  @moduledoc """
  Durable identity, intent and fenced ownership for organizer events.

  Source transactions lock source rows before this row. Reconciliation never
  locks a source row and never holds a transaction across Google I/O. A lease
  survives a crashed driver; every mutation also uses Google's event identity
  or ETag so an expired owner cannot blindly overwrite a newer provider state.
  """
  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.WorkshopCalendar.Event
  alias Dhc.WorkshopCalendar.Workers.SyncWorker

  @lease_seconds 120
  @max_attempts 6

  def record(kind, id, deleted) do
    unless Repo.in_transaction?(), do: raise("Calendar intent requires the source transaction")

    ensure(kind, id)

    from(e in Event, where: e.source_kind == ^to_string(kind) and e.source_id == ^id)
    |> Repo.update_all(
      inc: [revision: 1],
      set: [deleted: deleted, removal_completed: false, updated_at: DateTime.utc_now()]
    )

    enqueue(kind, id)
    :ok
  end

  def ensure(kind, id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Event,
      [
        %{
          id: Ecto.UUID.generate(),
          source_kind: to_string(kind),
          source_id: id,
          audience: "committee",
          event_id: event_id(kind, id, 0),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:source_kind, :source_id, :audience]
    )

    :ok
  end

  def enqueue(kind, id, delay \\ 0) do
    %{source_kind: to_string(kind), source_id: id}
    |> SyncWorker.new(schedule_in: delay)
    |> Oban.insert!()
  end

  def claim(kind, id, now) do
    now = timestamp(now)

    {:ok, result} =
      Repo.transaction(fn ->
        event =
          Repo.one!(
            from(e in Event,
              where: e.source_kind == ^to_string(kind) and e.source_id == ^id,
              lock: "FOR UPDATE"
            )
          )

        claim_available(event, now)
      end)

    result
  end

  defp claim_available(event, now) do
    cond do
      event.removal_completed ->
        {:skip, :removed}

      event.lease_until && DateTime.compare(event.lease_until, now) == :gt ->
        {:skip, :busy}

      event.failure && is_nil(event.retry_at) ->
        {:skip, :failed}

      event.retry_at && DateTime.compare(event.retry_at, now) == :gt ->
        {:skip, :backoff}

      true ->
        claimed =
          persist(event, %{
            lease_token: Ecto.UUID.generate(),
            lease_until: DateTime.add(now, @lease_seconds),
            attempts: event.attempts + 1
          })

        {:ok, claimed}
    end
  end

  def exhausted?(event), do: event.attempts > @max_attempts

  def bind_calendar(event, calendar_id) do
    owned(event, fn current ->
      cond do
        is_nil(current.calendar_id) -> {:ok, persist(current, %{calendar_id: calendar_id})}
        current.calendar_id == calendar_id -> {:ok, current}
        true -> {:error, :configuration}
      end
    end)
  end

  # A deleted Google event may remain as a tombstone forever. Persist the new
  # generation before attempting insert, including on the first absent ack.
  def next_generation(event) do
    owned(event, fn current ->
      generation = current.generation + 1

      {:ok,
       persist(current, %{
         generation: generation,
         event_id: event_id(current.source_kind, current.source_id, generation),
         create_requested: false,
         acknowledged: nil
       })}
    end)
  end

  # Persist the possibility of an ambiguous create before starting HTTP, and
  # refuse a stale lease/revision even if the driver's old source view matches.
  def prepare_create(event) do
    owned(event, fn current ->
      if current.revision == event.revision and not current.deleted do
        persist(current, %{create_requested: true})
        :ok
      else
        {:skip, :changed}
      end
    end)
  end

  def finish(event, acknowledged, _now, opts \\ []) do
    owned(event, fn current ->
      stale? = current.revision != event.revision or Keyword.get(opts, :stale, false)

      persist(current, %{
        acknowledged: acknowledged,
        removal_completed: Keyword.get(opts, :removed, false) and not stale?,
        lease_token: nil,
        lease_until: nil,
        attempts: 0,
        retry_at: nil,
        failure: nil,
        failure_episode: nil,
        alerted_at: nil
      })

      if stale?, do: {:snooze, 1}, else: :ok
    end)
  end

  def release(event) do
    owned(event, fn current ->
      persist(current, %{
        lease_token: nil,
        lease_until: nil,
        attempts: max(current.attempts - 1, 0)
      })

      :ok
    end)
  end

  def fail(event, reason, now) do
    now = timestamp(now)

    owned(event, fn current ->
      retry? = reason in [:transient, :conflict] and current.attempts < @max_attempts
      delay = min(30 * Integer.pow(2, min(current.attempts - 1, 6)), 1800)
      failure = if reason == :exhausted, do: "exhausted", else: to_string(reason)

      failed =
        persist(current, %{
          lease_token: nil,
          lease_until: nil,
          retry_at: if(retry?, do: DateTime.add(now, delay)),
          failure: failure,
          failure_episode: current.failure_episode || Ecto.UUID.generate()
        })

      if retry?, do: {:retry, delay}, else: {:failed, failed}
    end)
  end

  def owned(event, fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        current = Repo.one!(from(e in Event, where: e.id == ^event.id, lock: "FOR UPDATE"))

        if current.lease_token == event.lease_token and current.generation == event.generation,
          do: fun.(current),
          else: {:skip, :superseded}
      end)

    result
  end

  def pending_sources do
    Repo.all(
      from(e in Event,
        where: not e.removal_completed,
        select: {e.source_kind, e.source_id}
      )
    )
  end

  def unalerted_failures do
    Repo.all(
      from(e in Event,
        where: not is_nil(e.failure) and is_nil(e.retry_at) and is_nil(e.alerted_at)
      )
    )
  end

  # Resume is an explicit operator action, unlike a periodic repair. Re-arm a
  # bounded attempt budget, keeping the episode/alert marker until success so
  # resuming unchanged broken credentials cannot spam retained Notifications.
  def resume_failed do
    from(e in Event, where: not is_nil(e.failure) and is_nil(e.retry_at))
    |> Repo.update_all(set: [failure: nil, attempts: 0, updated_at: DateTime.utc_now()])

    :ok
  end

  def persist(event, attrs), do: event |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp timestamp(now),
    do: now |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)

  defp event_id(kind, id, generation) do
    :crypto.hash(:sha256, "#{kind}:#{id}:committee:#{generation}")
    |> Base.encode16(case: :lower)
  end
end
