defmodule Dhc.BeginnersWorkshops.IntakePolicyFactsTest do
  @moduledoc """
  ALE-402: `IntakePolicy` over its closed facts (`facts/1`): the
  constructor, the no-Intake Withdraw of the Waitlist tab, and
  `refund_carried_fee`'s delegation to `CarriedFeePolicy`.
  """

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.{CarriedFee, CarriedFeePolicy, IntakePolicy}

  @now ~U[2026-10-22 12:00:00Z]

  @linked %CarriedFee{
    status: "held",
    origin: "import",
    stripe_payment_intent_id: "pi_1",
    amount_cents: 3500
  }

  defp facts(opts) do
    [
      intake: %{state: "contacted", paid_via: nil, invitation_outcome: nil},
      entry: %{status: "waiting", removed_at: nil},
      carried_fee: nil,
      carried_fee_refund: nil,
      latest_fee_refunded: false,
      workshop_status: "scheduled",
      correction: nil,
      now: @now
    ]
    |> Keyword.merge(opts)
    |> IntakePolicy.facts()
  end

  defp intake(state, extra \\ %{}),
    do: Map.merge(%{state: state, paid_via: nil, invitation_outcome: nil}, extra)

  describe "facts/1" do
    test "requires every key" do
      keys = [
        :intake,
        :entry,
        :carried_fee,
        :carried_fee_refund,
        :latest_fee_refunded,
        :workshop_status,
        :correction,
        :now
      ]

      for key <- keys do
        assert_raise KeyError, fn ->
          [
            intake: nil,
            entry: nil,
            carried_fee: nil,
            carried_fee_refund: nil,
            latest_fee_refunded: false,
            workshop_status: nil,
            correction: nil,
            now: @now
          ]
          |> Keyword.delete(key)
          |> IntakePolicy.facts()
        end
      end
    end

    test "is a closed struct" do
      assert_raise ArgumentError, fn -> struct!(IntakePolicy, state: "paid") end
    end

    test "an anonymised attendee's standing is what became of them" do
      for outcome <- ~w(invited joined) do
        assert %IntakePolicy{standing: ^outcome} =
                 facts(intake: intake("attended", %{invitation_outcome: outcome}), entry: nil)
      end

      assert %IntakePolicy{standing: nil} =
               facts(intake: intake("attended", %{invitation_outcome: "not_invited"}), entry: nil)

      assert %IntakePolicy{standing: "attended"} =
               facts(
                 intake: intake("attended", %{invitation_outcome: "invited"}),
                 entry: %{status: "attended", removed_at: nil}
               )
    end

    test "the Carried Fee is the person's live one, as CarriedFeePolicy facts" do
      assert %IntakePolicy{carried_fee: %CarriedFeePolicy{status: "held", linked: true}} =
               facts(carried_fee: @linked)

      assert_raise ArgumentError, fn -> facts(carried_fee: %{@linked | status: "spent"}) end
    end
  end

  describe "withdraw with no open Intake (the Waitlist tab)" do
    test "is already done once removed with no live fee; otherwise it acts" do
      removed = %{status: "removed", removed_at: ~U[2026-10-01 12:00:00Z]}

      assert IntakePolicy.check(:withdraw, facts(intake: nil, entry: removed)) == :already_done

      assert IntakePolicy.check(
               :withdraw,
               facts(intake: nil, entry: removed, carried_fee: @linked)
             ) ==
               :ok

      assert IntakePolicy.check(:withdraw, facts(intake: nil)) == :ok
      assert IntakePolicy.check(:withdraw, facts(intake: nil, latest_fee_refunded: true)) == :ok

      # ALE-417: Onboarding's people, as the Settlement's withdrawal refuses them.
      for standing <- ~w(invited joined) do
        entry = %{status: standing, removed_at: nil}

        assert IntakePolicy.check(:withdraw, facts(intake: nil, entry: entry)) ==
                 {:error, :already_invited}
      end
    end

    test "needs the refund-or-forfeit choice exactly when a live fee exists" do
      refute IntakePolicy.refund_choice_required?(facts(intake: nil))
      assert IntakePolicy.refund_choice_required?(facts(intake: nil, carried_fee: @linked))
    end
  end

  describe "refund_carried_fee" do
    test "delegates the fee to CarriedFeePolicy" do
      unlinked = %CarriedFee{status: "held", origin: "import"}
      old = %{status: "removed", removed_at: ~U[2026-01-01 12:00:00Z]}

      cases = [
        {facts(carried_fee: @linked), :ok},
        {facts(carried_fee: unlinked), {:error, :payment_not_linked}},
        {facts(carried_fee: @linked, entry: old), {:error, :fee_not_refundable}},
        {facts(carried_fee: %{@linked | status: "applied"}), {:error, :no_carried_fee}},
        {facts(latest_fee_refunded: true), :already_done},
        {facts([]), {:error, :no_carried_fee}},
        {facts(intake: intake("paid", %{paid_via: "stripe"}), carried_fee: @linked),
         {:error, :already_paid}}
      ]

      for {facts, decision} <- cases,
          do: assert(IntakePolicy.check(:refund_carried_fee, facts) == decision, inspect(facts))
    end

    test "is offered for a held fee only once it can be refunded through Stripe" do
      assert :refund_carried_fee in IntakePolicy.available_commands(facts(carried_fee: @linked))

      refute :refund_carried_fee in IntakePolicy.available_commands(
               facts(carried_fee: %CarriedFee{status: "held", origin: "import"})
             )
    end
  end

  test "correct_attendance reads the workshop status, the standing and the correction" do
    finalised = fn opts ->
      facts(Keyword.merge([intake: intake("attended"), workshop_status: "finalised"], opts))
    end

    assert IntakePolicy.check(:correct_attendance, finalised.([])) == :ok
    assert IntakePolicy.check(:correct_attendance, finalised.(correction: "no_show")) == :ok

    assert IntakePolicy.check(:correct_attendance, finalised.(correction: "attended")) ==
             :already_done

    assert IntakePolicy.check(:correct_attendance, finalised.(correction: "deferred")) ==
             {:error, :not_correctable}

    assert IntakePolicy.check(
             :correct_attendance,
             finalised.(entry: nil, intake: intake("attended", %{invitation_outcome: "joined"}))
           ) == {:error, :already_invited}

    assert IntakePolicy.attendance_corrections(finalised.([])) == ["no_show"]
  end
end
