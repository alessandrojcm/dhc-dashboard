defmodule Dhc.BeginnersWorkshops.IntakePolicy do
  @moduledoc """
  Pure rules for the console's Intake commands (ALE-386), shared by the
  boundary (`Dhc.BeginnersWorkshops.Commands`, deciding under the lock) and
  the console read model (`WorkshopConsole`, advising without one) — the
  `Dhc.Inventory.LoanPolicy` precedent. Nothing here reads the database or
  the clock.

  `check/2` is the one rule per command:

    * `:ok` — the command would act now;
    * `:already_done` — the Intake is already where the command leads, so
      repeating it succeeds and does nothing again;
    * `{:error, reason}` — refused with a named reason.

  `available_commands/1` is exactly the commands whose `check/2` is `:ok`,
  so what the console offers can be stale but never *different* from what
  the boundary decides. A later Intake command joins `@commands` and gets a
  `check/2` clause here.
  """

  @type command :: :decline | :resend_link | :rotate_link
  @type decision :: :ok | :already_done | {:error, :already_paid | :intake_closed}

  @commands [:decline, :resend_link, :rotate_link]
  @open_states ~w(contacted paid)

  @doc "Every console Intake command, in display order."
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc """
  Whether `command` may run on an Intake in its current `state`:

    * `decline` — a `contacted` Intake becomes `declined`; a `declined` one
      is already there; a `paid` one is `:already_paid` (defer, cancel with
      refund or withdraw instead); every other state is `:intake_closed`;
    * `resend_link` / `rotate_link` — open Intakes only (`:intake_closed`).
      They have no target state, so each run sends again.
  """
  @spec check(command(), %{state: String.t()}) :: decision()
  def check(:decline, %{state: "contacted"}), do: :ok
  def check(:decline, %{state: "declined"}), do: :already_done
  def check(:decline, %{state: "paid"}), do: {:error, :already_paid}
  def check(:decline, %{state: _closed}), do: {:error, :intake_closed}

  def check(command, %{state: state}) when command in [:resend_link, :rotate_link],
    do: if(state in @open_states, do: :ok, else: {:error, :intake_closed})

  @doc "The commands the console offers for an Intake: those `check/2` allows now."
  @spec available_commands(%{state: String.t()}) :: [command()]
  def available_commands(intake), do: Enum.filter(@commands, &(check(&1, intake) == :ok))
end
