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
    CarriedFee,
    CarriedFeeView,
    Clock,
    Commands,
    DoorView,
    FastTrackCandidates,
    Intake,
    IntakeEmailLog,
    IntakePage,
    Invitable,
    MyWorkshops,
    Report,
    StaffCandidates,
    WorkshopConsole,
    WorkshopList
  }

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

    owed =
      from(i in Intake,
        left_join: l in IntakeEmailLog,
        on: l.intake_id == i.id and l.occasion == "follow_up",
        where: i.state == "attended" and not is_nil(i.waitlist_id) and is_nil(l.id),
        select: i.workshop_id
      )

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
  # once per schedule (`IntakeEmailLog.pre_workshop_occasion/1`, ALE-394).
  defp cutoff_owed_ids(now) do
    owed =
      from(i in Intake,
        as: :intake,
        join: w in BeginnersWorkshop,
        on: w.id == i.workshop_id,
        left_join: l in IntakeEmailLog,
        on:
          l.intake_id == i.id and
            l.occasion ==
              fragment(
                "CASE WHEN ? = 0 THEN 'pre_workshop' ELSE 'pre_workshop:' || ? END",
                w.reschedule_count,
                w.reschedule_count
              ),
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
            (i.state == "paid" and not is_nil(i.waitlist_id) and is_nil(l.id)),
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
  The status of each person's live Carried Fee (ALE-388), for the Waitlist
  view: `%{waitlist_id => "held" | "applied"}`; people without one are
  absent. The Waitlist cannot read Beginners' Workshops, so the dashboard
  asks here.
  """
  @spec carried_fees([binary()]) :: %{binary() => String.t()}
  def carried_fees([]), do: %{}

  def carried_fees(waitlist_ids) when is_list(waitlist_ids) do
    live = CarriedFee.live_statuses()

    from(f in CarriedFee,
      where: f.waitlist_id in ^waitlist_ids and f.status in ^live,
      select: {f.waitlist_id, f.status}
    )
    |> Repo.all()
    |> Map.new()
  end

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
