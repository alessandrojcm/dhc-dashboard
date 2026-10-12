defmodule Dhc.BeginnersWorkshops.SettlementTableTest do
  @moduledoc """
  ALE-404: every row of `Commands.Settlement`'s table only makes moves the
  transition table (`Commands.transitions/0`) and the Waitlist standing
  table (`Dhc.Waitlist.Standing`) allow, from the states the row declares
  it starts from.
  """

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.Commands
  alias Dhc.BeginnersWorkshops.Commands.Settlement
  alias Dhc.Waitlist.Standing

  @rows [
    {:finalisation, :attended},
    {:finalisation, :no_show},
    {:cutoff, :lapse},
    {:cutoff, :return},
    {:correct_attendance, "attended"},
    {:correct_attendance, "no_show"},
    {:correct_attendance, "deferred"},
    {:defer, :paid},
    {:cancel_workshop, :paid},
    {:cancel_workshop, :paid_anonymised},
    {:cancel_workshop, :contacted},
    {:cancel_with_refund, :stripe_paid},
    {:cancel_with_refund, :carried_fee_paid},
    {:decline, :contacted},
    {:withdraw, :contacted},
    {:withdraw, :stripe_paid},
    {:withdraw, :carried_fee_paid},
    {:withdraw, :no_intake},
    {:refund_carried_fee, :open_intake},
    {:refund_carried_fee, :no_intake},
    {:delete_person, :deleted},
    {:purge_retention, :purged}
  ]

  test "the table has exactly one row per cause and ending" do
    assert Enum.sort(Map.keys(Settlement.table())) == Enum.sort(@rows)
  end

  for key <- @rows do
    test "#{inspect(key)} makes only legal moves" do
      %{from: from, steps: steps} = Map.fetch!(Settlement.table(), unquote(Macro.escape(key)))
      steps = flatten(steps)
      assert steps != []

      for step <- steps do
        assert_legal(step, from)
      end
    end
  end

  test "correct_attendance's standings are attended, removed and waiting" do
    standings =
      for to <- ~w(attended no_show deferred) do
        %{steps: steps} = Map.fetch!(Settlement.table(), {:correct_attendance, to})
        for({:standing, standing, :required} <- steps, do: standing)
      end

    assert standings == [["attended"], ["removed"], ["waiting"]]
  end

  defp flatten(steps) do
    Enum.flat_map(steps, fn
      {:by_choice, refunded, forfeited} -> flatten(refunded) ++ flatten(forfeited)
      step -> [step]
    end)
  end

  defp assert_legal({:close, to}, from), do: assert_moves(:intake, from, :intake, to)

  defp assert_legal(:release_holds, from), do: assert_moves(:payment, from, :payment, "releasing")

  defp assert_legal({:standing, to, rule}, from) do
    assert rule in [:from_removed, :from_waiting, :withdrawal, :if_allowed, :required]
    starts = Map.fetch!(from, :standing)
    assert starts != []

    for start <- starts do
      assert Standing.allowed?(start, to), "standing #{start} → #{to} is not in Waitlist.Standing"
    end
  end

  defp assert_legal({:paying_fee, to}, from), do: assert_fee(from, to)

  # A Stripe payer's deferral creates a `held` fee; a Carried-Fee-paid one's
  # fee moves back to `held`.
  defp assert_legal(:carry, from), do: assert_fee(from, "held")

  defp assert_legal({:refund_payment, reason}, _from), do: assert(is_binary(reason))

  defp assert_legal({:refund_fee, selector, reason}, from) do
    assert selector in [:paying, :live]
    assert is_binary(reason)
    assert_fee(from, "refunded")
  end

  defp assert_legal({:forfeit_fee, :live}, from), do: assert_fee(from, "forfeited")

  defp assert_legal({:notice, email, _occasion}, _from), do: assert(is_binary(email))

  defp assert_legal(:follow_up_when_due, _from), do: :ok

  defp assert_fee(from, to), do: assert_moves(:carried_fee, from, :carried_fee, to)

  defp assert_moves(level, from, entity, to) do
    starts = Map.fetch!(from, level)
    assert starts != []

    for start <- starts do
      allowed = Commands.transitions() |> Map.fetch!(entity) |> Map.get(start, [])
      assert to in allowed, "#{entity} #{start} → #{to} is not in Commands.transitions/0"
    end
  end
end
