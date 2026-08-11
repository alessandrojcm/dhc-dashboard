defmodule Dhc.Onboarding.StripeAdapter.Live do
  @moduledoc false

  @behaviour Dhc.Onboarding.StripeAdapter

  alias Dhc.Invitations.Pricing

  @impl true
  def preview_membership(coupon_code), do: Pricing.preview_membership(coupon_code)

  @impl true
  def create_customer(attrs) do
    payment_processor().create_customer(
      attrs.email,
      attrs.name,
      attrs.invited_by_id,
      attrs.attempt_id
    )
  end

  @impl true
  def provision_membership(attrs) do
    case payment_processor().complete(attrs) do
      :ok -> {:ok, %{}}
      {:ok, state} when is_map(state) -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  defp payment_processor do
    Application.get_env(:dhc, :invitation_payment_processor, Dhc.Invitations.StripePayment)
  end
end
