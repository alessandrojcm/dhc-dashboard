defmodule Dhc.OnboardingE2EStripeAdapter do
  @moduledoc false

  @behaviour Dhc.Onboarding.StripeAdapter

  @probe __MODULE__.Probe

  def start_probe do
    ensure_probe!()
    Agent.update(@probe, fn _state -> %{active: true, invocations: []} end)
    :ok
  end

  def finish_probe do
    ensure_probe!()

    Agent.get_and_update(@probe, fn state ->
      {Enum.reverse(state.invocations), %{active: false, invocations: []}}
    end)
  end

  @impl true
  def preview_membership(coupon_code) do
    guarded_call(:preview_membership, fn ->
      Dhc.Onboarding.StripeAdapter.Live.preview_membership(coupon_code)
    end)
  end

  @impl true
  def prepare_payment(coupon_code) do
    guarded_call(:prepare_payment, fn ->
      Dhc.Onboarding.StripeAdapter.Live.prepare_payment(coupon_code)
    end)
  end

  @impl true
  def create_customer(attrs) do
    guarded_call(:create_customer, fn ->
      Dhc.Onboarding.StripeAdapter.Live.create_customer(attrs)
    end)
  end

  @impl true
  def provision_membership(attrs) do
    guarded_call(:provision_membership, fn ->
      Dhc.Onboarding.StripeAdapter.Live.provision_membership(attrs)
    end)
  end

  @impl true
  def cancel_membership(stripe_state) do
    guarded_call(:cancel_membership, fn ->
      Dhc.Onboarding.StripeAdapter.Live.cancel_membership(stripe_state)
    end)
  end

  @impl true
  def retryable_failure?(reason),
    do: Dhc.Onboarding.StripeAdapter.Live.retryable_failure?(reason)

  defp guarded_call(operation, fallback) do
    ensure_probe!()

    probed? =
      Agent.get_and_update(@probe, fn
        %{active: true, invocations: invocations} = state ->
          {true, %{state | invocations: [operation | invocations]}}

        state ->
          {false, state}
      end)

    if probed? do
      {:error, {:unexpected_e2e_stripe_call, operation}}
    else
      fallback.()
    end
  end

  defp ensure_probe! do
    case Process.whereis(@probe) do
      nil ->
        case Agent.start(fn -> %{active: false, invocations: []} end, name: @probe) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end
end
