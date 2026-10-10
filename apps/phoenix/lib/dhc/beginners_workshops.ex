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
    Clock,
    Commands,
    DoorView,
    MyWorkshops,
    StaffCandidates,
    WorkshopConsole,
    WorkshopList
  }

  alias Dhc.Repo

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
  The periodic sweep (ALE-380): runs every time-driven pass through
  `execute/3` as `:system` for each scheduled workshop still before its
  Payment Cutoff. Today that is `send_due_batch`; the cutoff, finalisation
  and follow-up passes join it with their tickets. A pass that is not due
  does nothing, so running the sweep again is safe — there are no
  per-workshop scheduled jobs.

  Returns how many passes sent a Batch, found nobody waiting, were not due,
  or failed.
  """
  @spec run_due_passes(keyword()) :: %{
          sent: non_neg_integer(),
          nobody_waiting: non_neg_integer(),
          not_due: non_neg_integer(),
          failed: non_neg_integer()
        }
  def run_due_passes(opts \\ []) do
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

  @doc "Every active Member the Staff dialog may pick, coaches marked."
  @spec staff_candidates() :: [StaffCandidates.t()]
  defdelegate staff_candidates(), to: StaffCandidates, as: :list
end
