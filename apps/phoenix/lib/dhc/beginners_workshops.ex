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

  alias Dhc.BeginnersWorkshops.{
    Clock,
    Commands,
    DoorView,
    MyWorkshops,
    StaffCandidates,
    WorkshopList
  }

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
