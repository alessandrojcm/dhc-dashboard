defmodule Dhc.BeginnersWorkshops.IntakeReplies.ReplyActionsTest do
  @moduledoc """
  ALE-411: the spec's intent → command table (ADR 0030), row by row, and the
  configuration gates in front of it (enabled, confidence threshold, the
  `money_back` yes/no thresholds).
  """

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.IntakeReplies.ReplyActions

  # The person's state as the table's columns name it.
  @contacted %ReplyActions{
    binding_open: true,
    open_intake: "contacted",
    held_fee: false,
    standing: "waiting",
    restorable: false
  }
  @paid %ReplyActions{
    binding_open: true,
    open_intake: "paid",
    held_fee: false,
    standing: "waiting",
    restorable: false
  }
  @fee_holder %ReplyActions{
    binding_open: false,
    open_intake: nil,
    held_fee: true,
    standing: "waiting",
    restorable: false
  }
  @no_intake %ReplyActions{
    binding_open: false,
    open_intake: nil,
    held_fee: false,
    standing: "waiting",
    restorable: false
  }

  describe "action/3: the table" do
    test "can't make this date" do
      for money <- [:yes, :no, :unclear],
          do:
            assert(
              {:ok, {:intake, :decline}} =
                ReplyActions.action("cant_make_date", money, @contacted)
            )

      assert {:ok, {:intake, :cancel_with_refund}} =
               ReplyActions.action("cant_make_date", :yes, @paid)

      # Money errs towards what can be undone.
      assert {:ok, {:intake, :defer}} = ReplyActions.action("cant_make_date", :no, @paid)
      assert {:ok, {:intake, :defer}} = ReplyActions.action("cant_make_date", :unclear, @paid)

      assert {:none, "no_reply_action"} = ReplyActions.action("cant_make_date", :yes, @fee_holder)
      assert {:none, "no_reply_action"} = ReplyActions.action("cant_make_date", :yes, @no_intake)
    end

    test "leaving the Waitlist" do
      for money <- [:yes, :no, :unclear] do
        assert {:ok, {:person, :withdraw}} =
                 ReplyActions.action("leaving_waitlist", money, @contacted)

        assert {:ok, {:person, :withdraw}} =
                 ReplyActions.action("leaving_waitlist", money, @no_intake)
      end

      for state <- [@paid, @fee_holder] do
        assert {:ok, {:person, :withdraw}} = ReplyActions.action("leaving_waitlist", :yes, state)
        assert {:none, "money_not_asked"} = ReplyActions.action("leaving_waitlist", :no, state)
        assert {:none, "money_unclear"} = ReplyActions.action("leaving_waitlist", :unclear, state)
      end

      # A contacted person who also holds a fee has money to settle too.
      holder = %{@contacted | held_fee: true}
      assert {:ok, {:person, :withdraw}} = ReplyActions.action("leaving_waitlist", :yes, holder)
      assert {:none, "money_unclear"} = ReplyActions.action("leaving_waitlist", :unclear, holder)

      # Someone already off the Waitlist has nothing to leave.
      removed = %{@no_intake | standing: "removed"}
      assert {:none, "no_reply_action"} = ReplyActions.action("leaving_waitlist", :yes, removed)
    end

    test "wants a refund" do
      assert {:ok, {:intake, :cancel_with_refund}} =
               ReplyActions.action("wants_refund", :no, @paid)

      assert {:ok, {:person, :refund_carried_fee}} =
               ReplyActions.action("wants_refund", :no, @fee_holder)

      assert {:none, "no_reply_action"} = ReplyActions.action("wants_refund", :yes, @contacted)
      assert {:none, "no_reply_action"} = ReplyActions.action("wants_refund", :yes, @no_intake)
    end

    test "wants to come back restores a removed person within retention (ALE-412)" do
      removed = %{@no_intake | standing: "removed", restorable: true}

      for money <- [:yes, :no, :unclear],
          do:
            assert(
              {:ok, {:person, :restore_person}} =
                ReplyActions.action("wants_to_come_back", money, removed)
            )

      # Past retention, still on the Waitlist, or with an open Intake: the
      # coordinator decides.
      past_retention = %{removed | restorable: false}
      removed_contacted = %{removed | open_intake: "contacted", binding_open: true}

      for state <- [@contacted, @paid, @fee_holder, @no_intake, past_retention, removed_contacted],
          do:
            assert(
              {:none, "no_reply_action"} = ReplyActions.action("wants_to_come_back", :no, state)
            )
    end

    test "lost or broken link" do
      assert {:ok, {:intake, :resend_link}} = ReplyActions.action("link_problem", :no, @contacted)
      assert {:ok, {:intake, :resend_link}} = ReplyActions.action("link_problem", :no, @paid)
      assert {:none, "no_reply_action"} = ReplyActions.action("link_problem", :no, @fee_holder)
      assert {:none, "no_reply_action"} = ReplyActions.action("link_problem", :no, @no_intake)
    end

    test "Intake intents act only on the Intake the email was about while it is open" do
      old_email = %{@paid | binding_open: false}

      assert {:none, "intake_not_open"} = ReplyActions.action("cant_make_date", :yes, old_email)
      assert {:none, "intake_not_open"} = ReplyActions.action("link_problem", :no, old_email)
      assert {:none, "intake_not_open"} = ReplyActions.action("wants_refund", :no, old_email)

      # Person intents act whichever email was answered.
      assert {:ok, {:person, :withdraw}} =
               ReplyActions.action("leaving_waitlist", :yes, old_email)

      old_holder = %{@contacted | binding_open: false, held_fee: true}

      assert {:ok, {:person, :refund_carried_fee}} =
               ReplyActions.action("wants_refund", :no, old_holder)
    end

    test "something else never acts" do
      assert {:none, "something_else"} = ReplyActions.action("something_else", :yes, @paid)
    end
  end

  describe "offered/1" do
    test "offers only the intents that could lead to a command now" do
      assert ReplyActions.offered(@contacted) ==
               ~w(cant_make_date leaving_waitlist link_problem)

      assert ReplyActions.offered(@paid) ==
               ~w(cant_make_date leaving_waitlist wants_refund link_problem)

      assert ReplyActions.offered(@fee_holder) == ~w(leaving_waitlist wants_refund)
      assert ReplyActions.offered(@no_intake) == ~w(leaving_waitlist)
      assert ReplyActions.offered(%{@no_intake | standing: "removed"}) == []

      assert ReplyActions.offered(%{@no_intake | standing: "removed", restorable: true}) ==
               ~w(wants_to_come_back)
    end
  end

  describe "decide/3" do
    @on %{
      intents: Map.new(ReplyActions.intents(), &{&1, %{enabled: true, threshold: 0.8}}),
      money_back: %{yes: 0.7, no: 0.3}
    }

    defp classification(intent, confidence, money_back),
      do: %{intent: intent, confidence: confidence, money_back: money_back}

    test "an enabled, confident intent maps through the table" do
      assert {:ok, {:intake, :decline}} =
               ReplyActions.decide(classification("cant_make_date", 0.9, 0.0), @contacted, @on)
    end

    test "a disabled intent needs the coordinator" do
      config = put_in(@on, [:intents, "cant_make_date", :enabled], false)

      assert {:none, "intent_disabled"} =
               ReplyActions.decide(
                 classification("cant_make_date", 0.99, 0.0),
                 @contacted,
                 config
               )
    end

    test "below its threshold needs the coordinator" do
      assert {:none, "below_threshold"} =
               ReplyActions.decide(classification("cant_make_date", 0.79, 0.0), @contacted, @on)
    end

    test "money_back between the thresholds is unclear on both paid branches" do
      assert {:ok, {:intake, :cancel_with_refund}} =
               ReplyActions.decide(classification("cant_make_date", 0.9, 0.7), @paid, @on)

      assert {:ok, {:intake, :defer}} =
               ReplyActions.decide(classification("cant_make_date", 0.9, 0.5), @paid, @on)

      assert {:ok, {:intake, :defer}} =
               ReplyActions.decide(classification("cant_make_date", 0.9, 0.3), @paid, @on)

      assert {:ok, {:person, :withdraw}} =
               ReplyActions.decide(classification("leaving_waitlist", 0.9, 0.7), @paid, @on)

      assert {:none, "money_unclear"} =
               ReplyActions.decide(classification("leaving_waitlist", 0.9, 0.5), @paid, @on)

      assert {:none, "money_not_asked"} =
               ReplyActions.decide(classification("leaving_waitlist", 0.9, 0.3), @fee_holder, @on)
    end

    test "something else needs the coordinator" do
      assert {:none, "something_else"} =
               ReplyActions.decide(classification("something_else", 0.99, 0.0), @paid, @on)
    end
  end

  describe "config/0" do
    test "every intent is off by default" do
      config = ReplyActions.config()
      assert Map.keys(config.intents) |> Enum.sort() == Enum.sort(ReplyActions.intents())
      assert Enum.all?(config.intents, fn {_intent, %{enabled: enabled}} -> enabled == false end)
      assert config.money_back.no < config.money_back.yes
    end

    test "any_enabled?/2 reads only the offered intents" do
      config = put_in(@on, [:intents, "wants_refund", :enabled], false)
      config = put_in(config, [:intents, "leaving_waitlist", :enabled], false)

      refute ReplyActions.any_enabled?(~w(leaving_waitlist wants_refund), config)
      assert ReplyActions.any_enabled?(~w(leaving_waitlist cant_make_date), config)
    end
  end
end
