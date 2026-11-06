defmodule Dhc.WorkshopCalendar do
  @moduledoc """
  The Workshop Calendar boundary. Google is a projection, never booking authority.

  Source changes record identifier-only intent in their existing transaction.
  Workers and periodic repair both run `sync/3`, always against current facts.
  Sending starts inactive; provisioning and reviewed activation belong to the
  launch workflow, not deploying this integration. Pause is durable across nodes
  and stops starting mutations, not requests already in flight.
  """
  import Ecto.Query

  alias Dhc.BeginnersWorkshops
  alias Dhc.Repo
  alias Dhc.WorkshopCalendar.{Alerts, Control, Recipients, Store, Sync}
  alias Dhc.Workshops

  @doc "Records a source change in the caller's transaction; never calls Google."
  def record_change(kind, id) when kind in [:workshop, :beginners_workshop],
    do: Store.record(kind, id, false)

  @doc "Retains deletion work before the source is removed, without a cascading FK."
  def record_deleted(:workshop = kind, id), do: Store.record(kind, id, true)

  @doc "Retains the participant's selected address with a newly confirmed logical place."
  def confirm_place(kind, id, place_id, recipient) when kind in [:workshop, :beginners_workshop],
    do: Recipients.confirm(kind, id, place_id, recipient)

  @doc "Records loss of a place in the causing transaction, independently of its refund."
  def remove_place(kind, id, place_id) when kind in [:workshop, :beginners_workshop],
    do: Recipients.remove(kind, id, place_id)

  @doc "Retains privacy removals before the caller anonymises/unlinks its locked places."
  def forget_places(kind, place_ids) when kind in [:workshop, :beginners_workshop],
    do: Recipients.forget(kind, place_ids)

  @doc "Operator-only address repair. Requires pause and no live event owner; never calls Google inline."
  def correct_recipient(kind, id, place_id, recipient)
      when kind in [:workshop, :beginners_workshop],
      do: Recipients.correct(kind, id, place_id, recipient)

  @doc "Reconciles one source through the same protocol used by every driver."
  def sync(kind, id, opts \\ []) when kind in [:workshop, :beginners_workshop] do
    if Repo.in_transaction?(),
      do: raise(ArgumentError, "Calendar synchronization requires a committed source transaction")

    if outbound?() do
      clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
      audience = opts |> Keyword.get(:audience, :committee) |> to_string()

      if audience not in ["committee", "participant"],
        do: raise(ArgumentError, "invalid Calendar audience")

      Store.ensure(kind, id, audience)

      case Store.claim(kind, id, clock.(), audience) do
        {:ok, event} -> Sync.run(event, clock)
        {:skip, :busy} -> {:snooze, 5}
        {:skip, _reason} -> :ok
      end
    else
      :ok
    end
  end

  @doc "Finds missed source wake-ups, drift, failed alerts and orphaned cleanup."
  def repair(opts \\ []) do
    if outbound?() do
      clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

      sources =
        Enum.map(Workshops.calendar_source_ids(clock.()), &{"workshop", &1, "committee"}) ++
          Enum.map(
            BeginnersWorkshops.calendar_source_ids(clock.()),
            &{"beginners_workshop", &1, "committee"}
          ) ++
          Store.pending_sources()

      sources
      |> Enum.uniq()
      |> Enum.each(fn
        {kind, id, "committee"} -> Store.enqueue(kind, id)
        {kind, id, audience} -> Store.enqueue_audience(kind, id, audience)
      end)

      Enum.each(Store.unalerted_failures(), &Alerts.deliver/1)
      Enum.each(Store.participant_events(), &Recipients.alert_failures/1)
    end

    :ok
  end

  @doc "Pauses new outbound mutations without discarding work."
  def pause, do: set_paused(true)

  @doc "Resumes current-state reconciliation; does not activate an inactive installation."
  def resume do
    :ok = Store.resume_failed()
    :ok = set_paused(false)
    repair()
  end

  @doc false
  def config, do: Application.get_env(:dhc, __MODULE__, [])

  @doc false
  def ended?(source, clock), do: DateTime.compare(clock.(), source.end_date) != :lt

  @doc false
  def outbound? do
    Keyword.get(config(), :active, false) == true and not Repo.get!(Control, 1).paused
  end

  defp set_paused(paused) do
    Repo.update_all(from(c in Control, where: c.id == 1), set: [paused: paused])
    :ok
  end
end
