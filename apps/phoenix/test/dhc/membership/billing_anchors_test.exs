defmodule Dhc.Membership.BillingAnchorsTest do
  use ExUnit.Case, async: true

  alias Dhc.Membership.BillingAnchors

  describe "annual_start/1" do
    test "is the coming 7 January from 31 December" do
      assert BillingAnchors.annual_start(~D[2026-12-31]) == ~D[2027-01-07]
    end

    test "is this year's 7 January from 1 to 6 January" do
      for day <- 1..6 do
        assert BillingAnchors.annual_start(Date.new!(2027, 1, day)) == ~D[2027-01-07]
      end
    end

    test "is next year's 7 January on 7 January itself and after it" do
      assert BillingAnchors.annual_start(~D[2027-01-07]) == ~D[2028-01-07]
      assert BillingAnchors.annual_start(~D[2027-01-08]) == ~D[2028-01-07]
      assert BillingAnchors.annual_start(~D[2026-07-15]) == ~D[2027-01-07]
    end
  end

  describe "monthly_start/1" do
    test "is the 1st of the following month, across the year end" do
      assert BillingAnchors.monthly_start(~D[2026-12-31]) == ~D[2027-01-01]
      assert BillingAnchors.monthly_start(~D[2027-01-01]) == ~D[2027-02-01]
      assert BillingAnchors.monthly_start(~D[2027-01-07]) == ~D[2027-02-01]
      assert BillingAnchors.monthly_start(~D[2026-07-15]) == ~D[2026-08-01]
    end
  end

  test "billing_starts/1 gives both dates as civil YYYY-MM-DD strings" do
    assert BillingAnchors.billing_starts(~U[2027-01-03 18:30:00Z]) == %{
             monthlyBillingStart: "2027-02-01",
             annualBillingStart: "2027-01-07"
           }

    assert BillingAnchors.billing_starts(~U[2026-07-15 09:00:00Z]) == %{
             monthlyBillingStart: "2026-08-01",
             annualBillingStart: "2027-01-07"
           }
  end

  test "config_anchor_unix/2 is the start date at the instant's UTC time-of-day" do
    now = ~U[2027-01-03 18:30:42.123456Z]

    assert BillingAnchors.config_anchor_unix(:annual, now) ==
             DateTime.to_unix(~U[2027-01-07 18:30:42Z])

    assert BillingAnchors.config_anchor_unix(:monthly, now) ==
             DateTime.to_unix(~U[2027-02-01 18:30:42Z])
  end

  test "subscription_anchor_config/1 is the constant creation-time config" do
    assert BillingAnchors.subscription_anchor_config(:monthly) == [
             {"billing_cycle_anchor_config[day_of_month]", "1"}
           ]

    assert BillingAnchors.subscription_anchor_config(:annual) == [
             {"billing_cycle_anchor_config[month]", "1"},
             {"billing_cycle_anchor_config[day_of_month]", "7"}
           ]
  end

  test "midnight_unix/1 is the date's midnight UTC" do
    assert BillingAnchors.midnight_unix(~D[2027-01-07]) ==
             DateTime.to_unix(~U[2027-01-07 00:00:00Z])
  end
end
