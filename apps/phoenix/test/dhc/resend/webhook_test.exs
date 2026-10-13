defmodule Dhc.Resend.WebhookTest do
  use ExUnit.Case, async: true

  alias Dhc.Resend.Webhook

  @secret "whsec_" <> Base.encode64("unit-test-secret")
  @payload ~s({"type":"email.received","data":{"email_id":"abc"}})
  @now 1_760_000_000

  defp headers(payload \\ @payload, timestamp \\ @now, secret \\ @secret) do
    %{
      id: "msg_1",
      timestamp: Integer.to_string(timestamp),
      signature: Webhook.sign(payload, "msg_1", timestamp, secret)
    }
  end

  test "accepts a delivery signed with the secret and returns the event" do
    assert {:ok, %{"type" => "email.received"}} =
             Webhook.verify(@payload, headers(), @secret, @now)
  end

  test "matches Svix's published test vector" do
    # docs.svix.com/receiving/verifying-payloads/how-manual
    secret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
    payload = ~s({"test": 2432232314})

    assert {:ok, %{"test" => 2_432_232_314}} =
             Webhook.verify(
               payload,
               %{
                 id: "msg_p5jXN8AQM9LWM0D4loKWxJek",
                 timestamp: "1614265330",
                 signature: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
               },
               secret,
               1_614_265_330
             )
  end

  test "accepts any of several signatures and any of several secrets" do
    other = "whsec_" <> Base.encode64("previous-secret")
    %{signature: signature} = headers()

    assert {:ok, _event} =
             Webhook.verify(
               @payload,
               %{headers() | signature: "v1,bm90LWl0 " <> signature},
               [other, @secret],
               @now
             )
  end

  test "refuses a signature made with another secret or over another body" do
    assert {:error, :no_matching_signature} =
             Webhook.verify(
               @payload,
               headers(@payload, @now, "whsec_" <> Base.encode64("x")),
               @secret,
               @now
             )

    assert {:error, :no_matching_signature} =
             Webhook.verify(@payload <> " ", headers(), @secret, @now)
  end

  test "refuses a stale or future timestamp" do
    assert {:error, :timestamp_expired} =
             Webhook.verify(@payload, headers(@payload, @now - 301), @secret, @now)

    assert {:error, :timestamp_expired} =
             Webhook.verify(@payload, headers(@payload, @now + 301), @secret, @now)
  end

  test "refuses missing or malformed headers" do
    assert {:error, :missing_header} =
             Webhook.verify(@payload, %{headers() | signature: nil}, @secret, @now)

    assert {:error, :invalid_header} =
             Webhook.verify(@payload, %{headers() | timestamp: "soon"}, @secret, @now)

    assert {:error, :invalid_header} =
             Webhook.verify(@payload, %{headers() | signature: "v2,abc"}, @secret, @now)
  end
end
