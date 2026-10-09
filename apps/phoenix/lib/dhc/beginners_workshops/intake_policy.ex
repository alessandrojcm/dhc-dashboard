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

  @type command ::
          :decline
          | :defer
          | :confirm
          | :cancel_with_refund
          | :withdraw
          | :refund_carried_fee
          | :resend_link
          | :rotate_link
          | :correct_attendance
  @type decision ::
          :ok
          | :already_done
          | {:error,
             :already_paid
             | :intake_closed
             | :intake_not_paid
             | :no_carried_fee}

  @typedoc """
  What the rule reads: the Intake's `state` (and `paid_via` once paid), and
  `carried_fee` — the status of the person's live Carried Fee, or `nil`
  (ALE-388; `confirm` and `refund_carried_fee` read it). `correct_attendance` (ALE-393) also
  reads `workshop_status`, the person's Waitlist `standing` (`nil` once
  anonymised) and `correction`, the state asked for (`nil` when the console
  asks whether any correction is possible).
  """
  @type facts :: %{
          required(:state) => String.t(),
          optional(:paid_via) => String.t() | nil,
          optional(:carried_fee) => String.t() | nil,
          optional(:workshop_status) => String.t(),
          optional(:standing) => String.t() | nil,
          optional(:correction) => String.t() | nil,
          optional(atom()) => term()
        }

  @commands [
    :decline,
    :defer,
    :confirm,
    :cancel_with_refund,
    :withdraw,
    :refund_carried_fee,
    :resend_link,
    :rotate_link,
    :correct_attendance
  ]
  @open_states ~w(contacted paid)

  # ALE-393: the attendance corrections, from → the states it may become.
  @corrections %{"attended" => ~w(no_show), "no_show" => ~w(attended deferred)}
  @correction_states ~w(attended no_show deferred)

  @doc "Every console Intake command, in display order."
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc """
  Whether `command` may run on an Intake in its current `state`:

    * `decline` — a `contacted` Intake becomes `declined`; a `declined` one
      is already there; a `paid` one is `:already_paid` (defer, cancel with
      refund or withdraw instead); every other state is `:intake_closed`;
    * `defer` (ALE-388) — a `paid` Intake becomes `deferred`; a `deferred`
      one is already there; a `contacted` one is `:intake_not_paid` (decline
      instead); every other state is `:intake_closed`;
    * `confirm` (ALE-388) — a `contacted` Intake whose person holds a `held`
      Carried Fee becomes `paid`; without one it is `:no_carried_fee`; an
      Intake already paid by confirmation is already there, one paid through
      Stripe is `:already_paid`; every other state is `:intake_closed`.
      Seats (`:full`) are judged by the boundary under the lock;
    * `cancel_with_refund` (ALE-387) — a `paid` Intake becomes
      `cancelled_refunded`, refunding the Stripe payment or (ALE-389) the
      Carried Fee that paid it; a `cancelled_refunded` one is already there;
      a `contacted` one is `:intake_not_paid` (decline or withdraw instead);
      every other state is `:intake_closed`;
    * `withdraw` (ALE-387) — a `contacted` Intake becomes `declined` and a
      `paid` one `withdrawn`; a `withdrawn` one is already there; every
      other state is `:intake_closed`. Whether the refund choice was given
      (required for a paid Intake and, ALE-389, whenever the person holds a
      Carried Fee) is the command's own input, not the Intake's state, so
      the boundary checks it;
    * `refund_carried_fee` (ALE-389) — the person's `held` Carried Fee is
      refunded; the Intake itself does not move (a `contacted` one stays
      contacted and asks for payment). A `paid` Intake is `:already_paid`
      (cancel with refund or withdraw instead); without a held fee it is
      `:no_carried_fee`. Whether the person may still have it refunded (not
      after attending) is judged by the boundary from their standing;
    * `resend_link` / `rotate_link` — open Intakes only (`:intake_closed`).
      They have no target state, so each run sends again;
    * `correct_attendance` (ALE-393) — after Attendance Finalisation only
      (`:before_finalisation`; a cancelled workshop is `:already_cancelled`):
      `attended → no_show`, `no_show → attended | deferred`. An Intake
      already in the asked state is already there; once the person's
      standing is `invited` or `joined` it is `:already_invited` (membership
      never rests on a changed record); any other move is
      `:not_correctable`. Without a `correction` it answers whether any
      correction is possible (the console's question).
  """
  @spec check(command(), facts()) :: decision()
  def check(:decline, %{state: "contacted"}), do: :ok
  def check(:decline, %{state: "declined"}), do: :already_done
  def check(:decline, %{state: "paid"}), do: {:error, :already_paid}
  def check(:decline, %{state: _closed}), do: {:error, :intake_closed}

  def check(:defer, %{state: "paid"}), do: :ok
  def check(:defer, %{state: "deferred"}), do: :already_done
  def check(:defer, %{state: "contacted"}), do: {:error, :intake_not_paid}
  def check(:defer, %{state: _closed}), do: {:error, :intake_closed}

  def check(:confirm, %{state: "contacted"} = facts),
    do: if(Map.get(facts, :carried_fee) == "held", do: :ok, else: {:error, :no_carried_fee})

  def check(:confirm, %{state: "paid"} = facts),
    do:
      if(Map.get(facts, :paid_via) == "carried_fee",
        do: :already_done,
        else: {:error, :already_paid}
      )

  def check(:confirm, %{state: _closed}), do: {:error, :intake_closed}

  def check(:cancel_with_refund, %{state: "paid"}), do: :ok
  def check(:cancel_with_refund, %{state: "cancelled_refunded"}), do: :already_done
  def check(:cancel_with_refund, %{state: "contacted"}), do: {:error, :intake_not_paid}
  def check(:cancel_with_refund, %{state: _closed}), do: {:error, :intake_closed}

  def check(:withdraw, %{state: "contacted"}), do: :ok
  def check(:withdraw, %{state: "paid"}), do: :ok
  def check(:withdraw, %{state: "withdrawn"}), do: :already_done
  def check(:withdraw, %{state: _closed}), do: {:error, :intake_closed}

  def check(:refund_carried_fee, %{state: "paid"}), do: {:error, :already_paid}

  def check(:refund_carried_fee, facts),
    do: if(Map.get(facts, :carried_fee) == "held", do: :ok, else: {:error, :no_carried_fee})

  def check(command, %{state: state}) when command in [:resend_link, :rotate_link],
    do: if(state in @open_states, do: :ok, else: {:error, :intake_closed})

  def check(:correct_attendance, facts) do
    case Map.get(facts, :workshop_status) do
      "finalised" -> check_correction(facts, Map.get(facts, :correction))
      "cancelled" -> {:error, :already_cancelled}
      _scheduled -> {:error, :before_finalisation}
    end
  end

  @doc """
  ALE-393: the states `correct_attendance` would move this Intake to now, in
  display order — each one `check/2` allows.
  """
  @spec attendance_corrections(facts()) :: [String.t()]
  def attendance_corrections(facts) do
    facts.state
    |> then(&Map.get(@corrections, &1, []))
    |> Enum.filter(&(check(:correct_attendance, Map.put(facts, :correction, &1)) == :ok))
  end

  @doc "The states an attendance correction may name."
  @spec correction_states() :: [String.t()]
  def correction_states, do: @correction_states

  # After finalisation: where the Intake already is, then the standing, then
  # the table.
  defp check_correction(%{state: state}, state), do: :already_done

  defp check_correction(facts, correction) do
    targets = Map.get(@corrections, facts.state, [])

    cond do
      Map.get(facts, :standing) in ~w(invited joined) -> {:error, :already_invited}
      correction == nil and targets != [] -> :ok
      correction in targets -> :ok
      true -> {:error, :not_correctable}
    end
  end

  @doc "The commands the console offers for an Intake: those `check/2` allows now."
  @spec available_commands(facts()) :: [command()]
  def available_commands(intake), do: Enum.filter(@commands, &(check(&1, intake) == :ok))
end
