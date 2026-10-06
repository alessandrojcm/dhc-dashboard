defmodule Dhc.Stripe.FailureTest do
  use ExUnit.Case, async: true

  alias Dhc.Stripe.Failure

  test "Stripe timeouts, conflicts, rate limits and server errors are retryable" do
    for status <- [408, 409, 429, 500, 502, 503, 599] do
      assert Failure.retryable?({:stripe_api, status, %{}}), "expected #{status} to be retryable"
    end
  end

  test "transport failures are retryable" do
    assert Failure.retryable?({:http_error, %Req.TransportError{reason: :timeout}})
  end

  test "other Stripe answers and local failures are not retryable" do
    for status <- [400, 401, 402, 403, 404, 422] do
      refute Failure.retryable?({:stripe_api, status, %{}}), "expected #{status} to be final"
    end

    refute Failure.retryable?({:stripe_api, "500", %{}})
    refute Failure.retryable?(:stripe_key_not_configured)
    refute Failure.retryable?(:timeout)
    refute Failure.retryable?(nil)
  end
end
