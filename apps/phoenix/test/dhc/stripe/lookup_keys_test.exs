defmodule Dhc.Stripe.LookupKeysTest do
  use ExUnit.Case, async: false

  alias Dhc.Stripe.LookupKeys

  setup do
    original = Application.get_env(:dhc, :stripe_membership_lookup_keys)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dhc, :stripe_membership_lookup_keys)
      else
        Application.put_env(:dhc, :stripe_membership_lookup_keys, original)
      end
    end)

    Application.delete_env(:dhc, :stripe_membership_lookup_keys)

    :ok
  end

  test "defaults to the existing Stripe membership lookup keys" do
    assert LookupKeys.monthly() == "standard_membership_fee"
    assert LookupKeys.annual() == "annual_membership_fee_revised"
    assert LookupKeys.all() == ["standard_membership_fee", "annual_membership_fee_revised"]
  end

  test "allows config to override individual lookup keys" do
    Application.put_env(:dhc, :stripe_membership_lookup_keys, monthly: "custom_monthly")

    assert LookupKeys.monthly() == "custom_monthly"
    assert LookupKeys.annual() == "annual_membership_fee_revised"
  end

  test "ignores blank configured lookup keys" do
    Application.put_env(:dhc, :stripe_membership_lookup_keys, %{
      "monthly" => " ",
      "annual" => "custom_annual"
    })

    assert LookupKeys.monthly() == "standard_membership_fee"
    assert LookupKeys.annual() == "custom_annual"
  end
end
