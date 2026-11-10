defmodule Dhc.BeginnersWorkshops do
  @moduledoc """
  Beginners' Workshops (CONTEXT.md, ADR 0029): the club's intake events
  between the Waitlist and Invitation. A top-level context with its own
  tables; it never reads or writes Workshop storage, and Waitlist and
  Onboarding never depend on it (Reach enforces both).

  **Every write goes through `execute/3`** (`Dhc.BeginnersWorkshops.Commands`):
  one lock order, one transition table, one `persist/1`, a clock read inside
  the lock. Reads are lock-free, actor-free read models; a route's capability
  gate is their authorization.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    CalendarProjection,
    CarriedFee,
    CarriedFeeView,
    Clock,
    Commands,
    DestinationEnrichment,
    DoorView,
    EndTimeReport,
    FastTrackCandidates,
    Intake,
    IntakeEmails,
    IntakePage,
    Invitable,
    MyWorkshops,
    PeopleView,
    Report,
    StaffCandidates,
    WorkshopConsole,
    WorkshopList
  }

  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.Import

  @doc """
  Executes one Beginners' Workshop command as `actor` — the only write path.
  See `Dhc.BeginnersWorkshops.Commands` for actors, commands and refusals.
  Pass `clock: Dhc.BeginnersWorkshops.Clock.fixed(now)` to fix the time.
  """
  @spec execute(Commands.actor(), Commands.command(), keyword()) ::
          {:ok, term()} | {:error, Commands.error()}
  defdelegate execute(actor, command, opts \\ []), to: Commands

  @doc """
  The Workshops list: upcoming first, then past and cancelled. Option
  `clock:` fixes the time the stages are judged at.
  """
  @spec list_workshops(keyword()) :: WorkshopList.t()
  def list_workshops(opts \\ []), do: WorkshopList.list(Clock.from_opts(opts))

  @doc """
  One workshop's console read model (ALE-380), or `{:error, :not_found}`.
  Option `clock:` fixes the time it is judged at.
  """
  @spec workshop_console(binary(), keyword()) ::
          {:ok, WorkshopConsole.t()} | {:error, :not_found}
  def workshop_console(workshop_id, opts \\ []),
    do: WorkshopConsole.show(workshop_id, Clock.from_opts(opts))

  @doc """
  The Invitable view (ALE-392): everyone with standing `attended`, across
  workshops, with the attended Intake to invite from, its workshop date and
  the Follow-up's status. See `Dhc.BeginnersWorkshops.Invitable`.
  """
  @spec invitable() :: [Invitable.t()]
  defdelegate invitable(), to: Invitable, as: :list

  @doc """
  The Dashboard tab's report (ALE-397): queue health, the last 12 months'
  planning figures and per-workshop outcomes. Report only; see
  `Dhc.BeginnersWorkshops.Report`. Option `clock:` fixes the time.
  """
  @spec report(keyword()) :: Report.t()
  def report(opts \\ []), do: Report.load(Clock.from_opts(opts))

  @doc """
  Read-only operational report of upcoming schedules with a missing or invalid
  end time. Calendar work can use it before launch; it makes no Google call.
  """
  @spec end_time_report(keyword()) :: [EndTimeReport.row()]
  def end_time_report(opts \\ []), do: EndTimeReport.load(Clock.from_opts(opts))

  @doc """
  The narrow Beginners' Workshop source projection for Workshop Calendar, or
  `nil` when the workshop no longer exists. It contains no person, payment,
  capacity, or Intake data. An unknown or invalid civil end time is `nil`;
  Calendar must fail closed rather than infer one.
  """
  @spec calendar_projection(binary()) ::
          %{
            id: binary(),
            title: String.t(),
            status: String.t(),
            start_date: DateTime.t() | nil,
            end_date: DateTime.t() | nil,
            location: String.t()
          }
          | nil
  def calendar_projection(workshop_id) when is_binary(workshop_id) do
    case Repo.get(BeginnersWorkshop, workshop_id) do
      nil -> nil
      workshop -> CalendarProjection.project(workshop)
    end
  end

  @doc """
  Returns Beginners' Workshop ids a Calendar repair pass must reconcile.

  Cancelled workshops remain sources after their end to repair a missed
  cancellation. A missing end remains discoverable while its start is future,
  so a completed authorized backfill can recover Calendar automatically.
  """
  @spec calendar_source_ids(DateTime.t()) :: [binary()]
  def calendar_source_ids(%DateTime{} = now) do
    BeginnersWorkshop
    |> Repo.all()
    |> Enum.filter(&CalendarProjection.current?(&1, now))
    |> Enum.map(& &1.id)
  end

  @doc "Closed projections for the upcoming sources selected during Calendar launch."
  @spec calendar_launch_sources(DateTime.t()) :: [map()]
  def calendar_launch_sources(%DateTime{} = now) do
    BeginnersWorkshop
    |> Repo.all()
    |> Enum.map(&CalendarProjection.project/1)
    |> Enum.filter(&(&1.status != "cancelled" and future_start?(&1, now)))
    |> Enum.sort_by(&{DateTime.to_unix(&1.start_date), &1.id})
  end

  @doc "Current confirmed Beginners' Workshop places and their linked Waitlist addresses."
  @spec calendar_launch_places(binary()) :: [%{place_id: binary(), recipient: String.t()}]
  def calendar_launch_places(workshop_id) when is_binary(workshop_id) do
    from(i in Intake,
      join: e in Dhc.Waitlist.WaitlistEntry,
      on: e.id == i.waitlist_id,
      where: i.workshop_id == ^workshop_id and i.state in ["paid", "attended", "no_show"],
      order_by: [asc: i.id],
      select: %{place_id: i.id, recipient: e.email}
    )
    |> Repo.all()
  end

  @doc "Materializes Calendar launch intent through the Beginners' Workshop write boundary."
  @spec materialize_calendar_launch(binary(), keyword()) ::
          :ok | {:error, :missing_end_time | :invalid_schedule}
  def materialize_calendar_launch(workshop_id, opts \\ []) when is_binary(workshop_id) do
    case execute(:system, {:materialize_calendar_launch, workshop_id}, put_clock(opts)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Confirmation facts for Calendar, including attendance history. A Settlement
  records explicit place loss in the retained binding; attendance corrections
  (including no-show to deferred) must not be interpreted as that removal.
  This read selects no recipient data and never creates an entitlement.
  """
  @spec calendar_place_ids(binary()) :: [binary()]
  def calendar_place_ids(workshop_id) when is_binary(workshop_id) do
    from(i in Intake,
      where: i.workshop_id == ^workshop_id and not is_nil(i.paid_at),
      order_by: [asc: i.id],
      select: i.id
    )
    |> Repo.all()
  end

  # ── Reviewed destination enrichment (ALE-444) ────────────────────────

  @doc """
  The closed facts (`Dhc.BeginnersWorkshops.DestinationEnrichment.facts/1`)
  of every Beginners' Workshop that has not yet ended at `now`, for the
  reviewed destination backfill preview (`Dhc.DestinationBackfill`). A
  workshop without a valid end time counts until its Dublin date has passed.
  Cancelled, finalised and already-started workshops are included so the
  preview can say why each is refused. Read-only: no person, Intake, payment
  or link data.
  """
  @spec destination_backfill_sources(DateTime.t()) :: [DestinationEnrichment.facts()]
  def destination_backfill_sources(%DateTime{} = now) do
    today = ClubCalendar.on_date(now)

    from(w in BeginnersWorkshop,
      where: w.date >= ^today,
      order_by: [asc: w.date, asc: w.start_time, asc: w.id]
    )
    |> Repo.all()
    |> Enum.map(&DestinationEnrichment.facts/1)
    |> Enum.filter(&not_ended?(&1, now))
  end

  defp not_ended?(%{ends_at: %DateTime{} = ends_at}, now),
    do: DateTime.compare(ends_at, now) == :gt

  defp not_ended?(%{ends_at: nil}, _now), do: true

  @doc """
  The advisory enrichment reading for one workshop's facts: the rule the
  `enrich_destination` command applies under the lock, without the
  reviewed-facts comparison.
  """
  @spec check_destination_enrichment(
          DestinationEnrichment.facts() | nil,
          DestinationEnrichment.destination(),
          DateTime.t()
        ) :: :change | :unchanged | {:refused, DestinationEnrichment.refusal()}
  defdelegate check_destination_enrichment(facts, proposed, now),
    to: DestinationEnrichment,
    as: :check

  @doc """
  Applies one reviewed same-Venue destination enrichment through `execute/3`
  (`{:enrich_destination, id, review}` in `Commands.Schedule`), as
  `{:staff, principal_id}` holding `beginners.workshops.manage`.

  `opts[:clock]` is a `Clock` or, as `Dhc.DestinationBackfill` passes it, a
  `(-> DateTime.t())`; it is read under the workshop lock. Returns
  `{:ok, :changed | :unchanged}` or `{:error, reason}`. Never a reschedule:
  no email, Staff Notification or schedule change, only the destination and
  its Calendar intent.
  """
  @spec enrich_destination(
          Commands.actor(),
          binary(),
          %{
            expected: DestinationEnrichment.expected(),
            destination: DestinationEnrichment.destination()
          },
          keyword()
        ) :: {:ok, :changed | :unchanged} | {:error, Commands.error()}
  def enrich_destination(actor, workshop_id, review, opts \\ []) do
    execute(actor, {:enrich_destination, workshop_id, review}, put_clock(opts))
  end

  # Calendar and the destination backfill pass a bare `(-> DateTime.t())`.
  defp put_clock(opts) do
    clock =
      case Keyword.get_lazy(opts, :clock, &Clock.system/0) do
        tick when is_function(tick, 0) -> %Clock{tick: tick}
        %Clock{} = clock -> clock
      end

    Keyword.put(opts, :clock, clock)
  end

  defp future_start?(%{start_date: %DateTime{} = start_date}, now),
    do: DateTime.compare(start_date, now) == :gt

  defp future_start?(_source, _now), do: false

  @doc """
  The person's Intake page behind an Intake link (ALE-381), or
  `{:error, :not_found}`. Options `clock:` and `returned_session:` (the
  Checkout Session id of a success return). See
  `Dhc.BeginnersWorkshops.IntakePage`.
  """
  @spec intake_page(String.t(), keyword()) :: {:ok, IntakePage.t()} | {:error, :not_found}
  def intake_page(token, opts \\ []) when is_binary(token),
    do: IntakePage.show(token, Clock.from_opts(opts), opts)

  @doc """
  The Fast-track dialog's search for `workshop_id` (ALE-384): waiting people
  and people removed within retention, without an open Intake, matching
  `search`. Option `clock:` fixes the time retention is judged at.
  """
  @spec fast_track_candidates(binary(), String.t() | nil, keyword()) ::
          {:ok, [FastTrackCandidates.t()]} | {:error, :not_found}
  def fast_track_candidates(workshop_id, search, opts \\ []),
    do: FastTrackCandidates.search(workshop_id, search, Clock.from_opts(opts))

  @doc """
  The periodic sweep (ALE-380): runs every time-driven pass through
  `execute/3` as `:system`. `send_due_batch` runs for each scheduled
  workshop still before its Payment Cutoff; `reap_holds` (ALE-381) runs once
  across every workshop, because a Seat Hold may outlive the cutoff; then
  `pass_payment_cutoff` (ALE-385) runs for each scheduled workshop past its
  cutoff that still owes something (a `contacted` Intake, or a `paid` one
  without Pre-workshop info), after the reaper so a hold Stripe ended in
  this sweep is settled in it too. Then `finalise_attendance` (ALE-391)
  runs for each scheduled workshop whose Dublin date has ended, and
  `send_follow_ups` for each finalised workshop with an attended Intake
  still owed its Follow-up. A pass that is not due does nothing, so
  running the sweep again is safe — there are no per-workshop scheduled
  jobs.

  Returns how many Batch passes sent a Batch, found nobody waiting, were
  not due, or failed; how many expired holds Stripe released, completed
  or has not ended yet (`holds_waiting`, retried by the next sweep); and
  what the cutoff passes did: Pre-workshop info queued, Intakes lapsed,
  Intakes returned, and Intakes left for Stripe to end their hold
  (`cutoff_awaiting_hold`); how many workshops were finalised
  (`finalised`, and `finalise_awaiting_hold` when one waits for a live
  Seat Hold) and how many Follow-ups were queued (`follow_ups`). Last,
  `purge_retention` (ALE-396) hard-deletes each person `removed` for more
  than the 3-month retention window (`purged`).
  """
  @spec run_due_passes(keyword()) :: %{
          sent: non_neg_integer(),
          nobody_waiting: non_neg_integer(),
          not_due: non_neg_integer(),
          failed: non_neg_integer(),
          holds_released: non_neg_integer(),
          holds_completed: non_neg_integer(),
          holds_waiting: non_neg_integer(),
          cutoff_pre_workshop: non_neg_integer(),
          cutoff_lapsed: non_neg_integer(),
          cutoff_returned: non_neg_integer(),
          cutoff_awaiting_hold: non_neg_integer(),
          finalised: non_neg_integer(),
          finalise_awaiting_hold: non_neg_integer(),
          follow_ups: non_neg_integer(),
          purged: non_neg_integer()
        }
  def run_due_passes(opts \\ []) do
    sum_failed = fn :failed, a, b -> a + b end

    opts
    |> run_batch_passes()
    |> Map.merge(run_reap_pass(opts), sum_failed)
    |> Map.merge(run_cutoff_passes(opts), sum_failed)
    |> Map.merge(run_finalise_passes(opts), sum_failed)
    |> Map.merge(run_follow_up_passes(opts), sum_failed)
    |> Map.merge(run_retention_passes(opts), sum_failed)
  end

  # How many people one sweep purges (`opts[:purge_batch]` overrides it);
  # the next sweep takes the rest.
  @purge_batch 100

  # The shortest 3 calendar months (28 February → 28 May) is 89 days, so
  # this unlocked filter finds everyone past retention and a few who are not
  # yet; `Waitlist.restorable?/2` narrows it, and the pass decides again
  # under the lock (ALE-396).
  @purge_filter_days 89

  defp run_retention_passes(opts) do
    now = Clock.read(Clock.from_opts(opts)).now
    before = now |> DateTime.add(-@purge_filter_days, :day) |> DateTime.truncate(:second)

    # Only people the purge can act on now are candidates, so one it must
    # leave (an open Intake, or someone `Waitlist.hard_delete/1` refuses)
    # never holds the front of the queue and starves the rest.
    open_intake =
      from(i in Intake,
        where: i.waitlist_id == parent_as(:entry).id and i.state in ^Intake.open_states()
      )

    from(w in Waitlist.deletable_entries_query(),
      where: w.status == "removed" and w.removed_at < ^before,
      where: not exists(subquery(open_intake)),
      order_by: [asc: w.removed_at, asc: w.id],
      select: {w.id, w.removed_at},
      limit: ^Keyword.get(opts, :purge_batch, @purge_batch)
    )
    |> Repo.all()
    |> Enum.reject(fn {_id, removed_at} -> Waitlist.restorable?(removed_at, now) end)
    |> Enum.reduce(%{purged: 0, failed: 0}, fn {id, _removed_at}, tally ->
      case execute(:system, {:purge_retention, id}, opts) do
        {:ok, %{outcome: :purged}} -> Map.update!(tally, :purged, &(&1 + 1))
        {:ok, %{outcome: :not_due}} -> tally
        {:error, _reason} -> Map.update!(tally, :failed, &(&1 + 1))
      end
    end)
  end

  defp run_finalise_passes(opts) do
    today = Clock.read(Clock.from_opts(opts)).today

    from(w in BeginnersWorkshop,
      where: w.status == "scheduled" and w.date < ^today,
      order_by: [asc: w.date, asc: w.id],
      select: w.id
    )
    |> Repo.all()
    |> Enum.reduce(%{finalised: 0, finalise_awaiting_hold: 0, failed: 0}, fn id, tally ->
      case execute(:system, {:finalise_attendance, id}, opts) do
        {:ok, %{outcome: :finalised}} ->
          Map.update!(tally, :finalised, &(&1 + 1))

        {:ok, %{outcome: :awaiting_hold}} ->
          Map.update!(tally, :finalise_awaiting_hold, &(&1 + 1))

        {:ok, %{outcome: :not_due}} ->
          tally

        {:error, _reason} ->
          Map.update!(tally, :failed, &(&1 + 1))
      end
    end)
  end

  # Only a filter (finalised workshops whose day has passed with an
  # attended Intake not yet followed up): the pass decides under the lock.
  defp run_follow_up_passes(opts) do
    today = Clock.read(Clock.from_opts(opts)).today

    owed = :follow_up |> IntakeEmails.owing() |> select([intake: i], i.workshop_id)

    from(w in BeginnersWorkshop,
      where: w.status == "finalised" and w.date < ^today and w.id in subquery(owed),
      order_by: [asc: w.date, asc: w.id],
      select: w.id
    )
    |> Repo.all()
    |> Enum.reduce(%{follow_ups: 0, failed: 0}, fn id, tally ->
      case execute(:system, {:send_follow_ups, id}, opts) do
        {:ok, %{outcome: :sent, follow_ups: sent}} ->
          Map.update!(tally, :follow_ups, &(&1 + sent))

        {:ok, %{outcome: :not_due}} ->
          tally

        {:error, _reason} ->
          Map.update!(tally, :failed, &(&1 + 1))
      end
    end)
  end

  @cutoff_tally %{
    cutoff_pre_workshop: 0,
    cutoff_lapsed: 0,
    cutoff_returned: 0,
    cutoff_awaiting_hold: 0,
    failed: 0
  }

  defp run_cutoff_passes(opts) do
    now = Clock.read(Clock.from_opts(opts)).now

    now
    |> cutoff_owed_ids()
    |> Enum.reduce(@cutoff_tally, fn id, tally ->
      case execute(:system, {:pass_payment_cutoff, id}, opts) do
        {:ok, %{outcome: :passed} = done} ->
          %{
            tally
            | cutoff_pre_workshop: tally.cutoff_pre_workshop + done.pre_workshop,
              cutoff_lapsed: tally.cutoff_lapsed + done.lapsed,
              cutoff_returned: tally.cutoff_returned + done.returned,
              cutoff_awaiting_hold: tally.cutoff_awaiting_hold + done.awaiting_hold
          }

        {:ok, %{outcome: :not_due}} ->
          tally

        {:error, _reason} ->
          Map.update!(tally, :failed, &(&1 + 1))
      end
    end)
  end

  # Only a filter, so a quiet workshop is not locked every sweep: the pass
  # itself decides what is owed under the lock. Pre-workshop info is owed
  # once per schedule (`IntakeEmails.owing/1`, ALE-394).
  defp cutoff_owed_ids(now) do
    pre_workshop = :pre_workshop |> IntakeEmails.owing() |> select([intake: i], i.id)

    owed =
      from(i in Intake,
        as: :intake,
        # A Carried Fee holder's contacted Intake stays open until
        # finalisation (ALE-388), so it owes the cutoff pass nothing.
        where:
          (i.state == "contacted" and
             not exists(
               from(f in CarriedFee,
                 where: f.waitlist_id == parent_as(:intake).waitlist_id and f.status == "held",
                 select: 1
               )
             )) or
            i.id in subquery(pre_workshop),
        select: i.workshop_id
      )

    from(w in BeginnersWorkshop,
      where: w.status == "scheduled" and w.payment_cutoff <= ^now and w.id in subquery(owed),
      order_by: [asc: w.date, asc: w.id],
      select: w.id
    )
    |> Repo.all()
  end

  defp run_reap_pass(opts) do
    case execute(:system, :reap_holds, opts) do
      {:ok, %{released: released, completed: completed, waiting: waiting}} ->
        %{holds_released: released, holds_completed: completed, holds_waiting: waiting, failed: 0}

      {:error, _reason} ->
        %{holds_released: 0, holds_completed: 0, holds_waiting: 0, failed: 1}
    end
  end

  defp run_batch_passes(opts) do
    now = Clock.read(Clock.from_opts(opts)).now

    from(w in BeginnersWorkshop,
      where: w.status == "scheduled" and w.payment_cutoff > ^now,
      order_by: [asc: w.date, asc: w.id],
      select: w.id
    )
    |> Repo.all()
    |> Enum.reduce(%{sent: 0, nobody_waiting: 0, not_due: 0, failed: 0}, fn id, tally ->
      case execute(:system, {:send_due_batch, id}, opts) do
        {:ok, %{outcome: outcome}} -> Map.update!(tally, outcome, &(&1 + 1))
        {:error, _reason} -> Map.update!(tally, :failed, &(&1 + 1))
      end
    end)
  end

  @doc """
  "My Beginners' Workshops": the principal's upcoming and same-day Staff
  assignments, soonest first. Option `clock:` fixes the time.
  """
  @spec my_workshops(binary(), keyword()) :: [MyWorkshops.row()]
  def my_workshops(principal_id, opts \\ []),
    do: MyWorkshops.list(principal_id, Clock.from_opts(opts))

  @doc """
  The door view of one workshop and the assignment-scope resource to
  authorize `beginners.workshops.run` against. Option `clock:` fixes the time.
  """
  @spec door_view(term(), keyword()) ::
          {:ok, DoorView.t(), DoorView.resource()} | {:error, :not_found}
  def door_view(workshop_id, opts \\ []), do: DoorView.load(workshop_id, Clock.from_opts(opts))

  @doc """
  The Waitlist tab's people (ALE-417): for each of `waitlist_ids` that names
  a Waitlist entry, their live Carried Fee status, the person commands the
  tab may offer and the refund-or-forfeit choice an offered Withdraw or
  Delete needs. The Waitlist cannot read Beginners' Workshops, so the
  dashboard asks here. Option `clock:` fixes the time retention is judged
  at. See `Dhc.BeginnersWorkshops.PeopleView`.
  """
  @spec people([binary()], keyword()) :: %{binary() => PeopleView.person()}
  def people(waitlist_ids, opts \\ []) when is_list(waitlist_ids),
    do: PeopleView.list(waitlist_ids, Clock.read(Clock.from_opts(opts)).now)

  @doc """
  One person's Carried Fee as the Waitlist tab shows it (ALE-389): the live
  one, else their latest, with its original payment, a failed refund still
  to follow up and what may be done with it. `{:error, :no_carried_fee}`
  when they never held one. Option `clock:` fixes the time retention is
  judged at. See `Dhc.BeginnersWorkshops.CarriedFeeView`.
  """
  @spec carried_fee(binary(), keyword()) ::
          {:ok, CarriedFeeView.t()} | {:error, :no_carried_fee | :person_not_found}
  def carried_fee(waitlist_id, opts \\ []),
    do: CarriedFeeView.show(waitlist_id, Clock.read(Clock.from_opts(opts)).now)

  @doc """
  The one-time Waitlist spreadsheet import (ALE-376) with its Carried Fees
  (ALE-388): `Dhc.Waitlist.Import.import_sheet/2`, with every row whose Paid
  cell is set given a `held` Carried Fee inside that row's transaction
  (`{:import_carried_fee, …}` through `execute/3`). The Waitlist cannot call
  up into Beginners' Workshops, so this is the entry point the mix task and
  `Dhc.Release.import_waitlist/2` use. `dry_run: true` rolls every row back.
  """
  @spec import_waitlist(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def import_waitlist(contents, opts \\ []) when is_binary(contents) do
    command_opts = Keyword.take(opts, [:clock])

    carried_fee = fn
      _waitlist_id, %{carried_fee?: false} ->
        :ok

      waitlist_id, %{carried_fee?: true, raw: raw} ->
        case execute(:system, {:import_carried_fee, waitlist_id, raw}, command_opts) do
          {:ok, _fee} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end

    Import.import_sheet(contents, Keyword.put(opts, :carried_fee, carried_fee))
  end

  @doc "Every active Member the Staff dialog may pick, coaches marked."
  @spec staff_candidates() :: [StaffCandidates.t()]
  defdelegate staff_candidates(), to: StaffCandidates, as: :list
end
