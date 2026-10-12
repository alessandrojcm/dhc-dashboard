defmodule Dhc.BeginnersWorkshops.CarriedFeePolicyTest do
  @moduledoc "ALE-402: `CarriedFeePolicy`'s table, over facts built by `facts/1`."

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.{CarriedFee, CarriedFeePolicy}

  @now ~U[2026-10-22 12:00:00Z]
  @recently ~U[2026-09-01 12:00:00Z]
  @long_ago ~U[2026-01-01 12:00:00Z]

  defp fee(status, opts \\ []) do
    origin = Keyword.get(opts, :origin, "import")
    linked = Keyword.get(opts, :linked, true)

    %CarriedFee{
      status: status,
      origin: origin,
      payment_id: if(origin == "deferral" and linked, do: Ecto.UUID.generate()),
      stripe_payment_intent_id: if(origin == "import" and linked, do: "pi_1"),
      amount_cents: if(origin == "import" and linked, do: 3500)
    }
  end

  defp facts(fee, opts \\ []) do
    CarriedFeePolicy.facts(
      fee: fee,
      refund: Keyword.get(opts, :refund),
      entry: Keyword.get(opts, :entry, %{status: "waiting", removed_at: nil}),
      now: @now
    )
  end

  defp failed(followed_up \\ false), do: %{status: "failed", followed_up: followed_up}

  describe "facts/1" do
    test "requires every key" do
      for key <- [:fee, :refund, :entry, :now] do
        opts = Keyword.delete([fee: nil, refund: nil, entry: nil, now: @now], key)
        assert_raise KeyError, fn -> CarriedFeePolicy.facts(opts) end
      end
    end

    test "reads linked, the refund and the standing from raw rows" do
      assert %CarriedFeePolicy{status: "held", origin: "import", linked: true} =
               facts(fee("held"))

      assert %CarriedFeePolicy{linked: false} = facts(fee("held", linked: false))

      assert %CarriedFeePolicy{linked: true} = facts(fee("held", origin: "deferral"))

      assert %CarriedFeePolicy{status: nil, origin: nil, linked: false, standing: nil} =
               facts(nil, entry: nil)

      assert %CarriedFeePolicy{refund: nil} = facts(fee("held"))
      assert %CarriedFeePolicy{refund: :failed} = facts(fee("held"), refund: failed())
      assert %CarriedFeePolicy{refund: :followed_up} = facts(fee("held"), refund: failed(true))

      assert %CarriedFeePolicy{refund: :not_failed} =
               facts(fee("held"), refund: %{status: "completed", followed_up: false})
    end
  end

  describe "refund" do
    test "the table" do
      removed = fn at -> %{status: "removed", removed_at: at} end

      cases = [
        {facts(fee("held")), :ok},
        {facts(fee("held", origin: "deferral")), :ok},
        {facts(fee("held"), entry: removed.(@recently)), :ok},
        {facts(fee("held"), entry: removed.(@long_ago)), {:error, :fee_not_refundable}},
        {facts(fee("held"), entry: %{status: "attended", removed_at: nil}),
         {:error, :fee_not_refundable}},
        {facts(fee("held"), entry: nil), {:error, :fee_not_refundable}},
        {facts(fee("held", linked: false)), {:error, :payment_not_linked}},
        {facts(fee("applied")), {:error, :carried_fee_applied}},
        {facts(fee("applied"), entry: removed.(@long_ago)), {:error, :fee_not_refundable}},
        {facts(fee("refunded")), :already_done},
        {facts(fee("spent")), {:error, :no_carried_fee}},
        {facts(fee("forfeited")), {:error, :no_carried_fee}},
        {facts(nil), {:error, :no_carried_fee}}
      ]

      for {facts, decision} <- cases,
          do: assert(CarriedFeePolicy.check(:refund, facts) == decision, inspect(facts))
    end
  end

  describe "link_payment" do
    test "the table" do
      assert CarriedFeePolicy.check(:link_payment, facts(fee("held", linked: false))) == :ok
      assert CarriedFeePolicy.check(:link_payment, facts(fee("applied", linked: false))) == :ok

      assert CarriedFeePolicy.check(:link_payment, facts(fee("held"))) ==
               {:error, :already_linked}

      assert CarriedFeePolicy.check(:link_payment, facts(fee("held", origin: "deferral"))) ==
               {:error, :not_imported}

      for status <- [nil, "spent", "refunded", "forfeited"] do
        fee = status && fee(status, linked: false)
        assert CarriedFeePolicy.check(:link_payment, facts(fee)) == {:error, :no_carried_fee}
      end
    end
  end

  describe "retry, manual and forfeit" do
    test "the refund must have failed and not been followed up" do
      for command <- [:retry, :manual, :forfeit] do
        assert CarriedFeePolicy.check(command, facts(fee("held"))) == {:error, :refund_not_failed}

        assert CarriedFeePolicy.check(
                 command,
                 facts(fee("held"), refund: %{status: "pending", followed_up: false})
               ) == {:error, :refund_not_failed}

        assert CarriedFeePolicy.check(command, facts(fee("held"), refund: failed(true))) ==
                 {:error, :refund_followed_up}
      end
    end

    test "the fee must still be owed back" do
      cases = [
        {"held", :ok, :ok},
        {"refunded", :ok, {:error, :carried_fee_not_held}},
        {"applied", {:error, :carried_fee_applied}, {:error, :carried_fee_applied}},
        {"spent", {:error, :carried_fee_not_held}, {:error, :carried_fee_not_held}},
        {"forfeited", {:error, :carried_fee_not_held}, {:error, :carried_fee_not_held}}
      ]

      for {status, follow_up, forfeit} <- cases do
        facts = facts(fee(status), refund: failed())
        assert CarriedFeePolicy.check(:retry, facts) == follow_up, status
        assert CarriedFeePolicy.check(:manual, facts) == follow_up, status
        assert CarriedFeePolicy.check(:forfeit, facts) == forfeit, status
      end
    end

    test "a refund with no Carried Fee is followed up, but never forfeited" do
      facts = facts(nil, refund: failed(), entry: nil)
      assert CarriedFeePolicy.check(:retry, facts) == :ok
      assert CarriedFeePolicy.check(:manual, facts) == :ok
      assert CarriedFeePolicy.check(:forfeit, facts) == {:error, :not_a_carried_fee_refund}
    end
  end

  describe "available/1" do
    test "offers what check/2 allows, and a follow-up instead of a new refund" do
      assert CarriedFeePolicy.available(facts(fee("held"))) == [:refund]
      assert CarriedFeePolicy.available(facts(fee("held", linked: false))) == [:link_payment]
      assert CarriedFeePolicy.available(facts(fee("applied", linked: false))) == [:link_payment]
      assert CarriedFeePolicy.available(facts(fee("refunded"))) == []

      assert CarriedFeePolicy.available(facts(fee("held"), refund: failed())) ==
               [:retry, :manual, :forfeit]

      assert CarriedFeePolicy.available(facts(fee("refunded"), refund: failed())) ==
               [:retry, :manual]

      assert CarriedFeePolicy.available(facts(fee("held"), refund: failed(true))) == [:refund]
    end
  end
end
