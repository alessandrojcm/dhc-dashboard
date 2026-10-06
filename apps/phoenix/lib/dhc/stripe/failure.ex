defmodule Dhc.Stripe.Failure do
  @moduledoc """
  Classifies the failures `Dhc.Stripe.Client` returns (ALE-342).

  Hand-written beside the generated `Dhc.Stripe.Error` struct (which
  `mix stripe.gen` overwrites), so the retry rule lives in one place for every
  caller that decides between "try again later" and "needs a human":
  Invitation Acceptance (`Dhc.Invitations.StripePayment`) and Workshop Refund
  submission (`Dhc.Workshops.PaymentCommands`).
  """

  @doc """
  `true` when retrying the same request may succeed: Stripe answered 408
  (timeout), 409 (idempotency/lock conflict), 429 (rate limit) or 5xx, or the
  request never got an answer (`{:http_error, exception}`). Every other
  failure, including other 4xx answers and a missing secret key, is not
  retryable.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:stripe_api, status, _body})
      when status in [408, 409, 429] or (is_integer(status) and status >= 500),
      do: true

  def retryable?({:http_error, _exception}), do: true
  def retryable?(_reason), do: false
end
