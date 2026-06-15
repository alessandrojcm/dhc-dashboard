defmodule Dhc.Stripe.WebhookTest do
  use ExUnit.Case, async: true

  alias Dhc.Stripe.Webhook

  @secret "whsec_test_signing_key_for_webhook_verification"

  describe "verify/4" do
    test "verifies a valid signature and returns parsed event" do
      payload = ~s({"id":"evt_123","type":"charge.succeeded","data":{"object":{"id":"ch_123"}}})

      sig_header = Webhook.generate_test_signature(payload, @secret)

      assert {:ok, %{"id" => "evt_123", "type" => "charge.succeeded"}} =
               Webhook.verify(payload, sig_header, @secret)
    end

    test "verifies with explicit tolerance" do
      payload = ~s({"type":"test"})
      sig_header = Webhook.generate_test_signature(payload, @secret)

      assert {:ok, _} = Webhook.verify(payload, sig_header, @secret, tolerance: 300)
    end

    test "rejects an expired timestamp" do
      payload = ~s({"type":"test"})
      # 600 seconds ago — well past the 300s default tolerance
      old_timestamp = System.system_time(:second) - 600
      sig_header = Webhook.generate_test_signature(payload, @secret, timestamp: old_timestamp)

      assert {:error, :timestamp_expired} = Webhook.verify(payload, sig_header, @secret)
    end

    test "accepts expired timestamp when tolerance is 0" do
      payload = ~s({"type":"test"})
      old_timestamp = System.system_time(:second) - 600
      sig_header = Webhook.generate_test_signature(payload, @secret, timestamp: old_timestamp)

      assert {:ok, _} = Webhook.verify(payload, sig_header, @secret, tolerance: 0)
    end

    test "rejects a wrong secret" do
      payload = ~s({"type":"test"})
      sig_header = Webhook.generate_test_signature(payload, @secret)

      assert {:error, :no_matching_signature} =
               Webhook.verify(payload, sig_header, "whsec_wrong_secret")
    end

    test "rejects a tampered payload" do
      payload = ~s({"type":"test"})
      sig_header = Webhook.generate_test_signature(payload, @secret)
      tampered_payload = ~s({"type":"tampered"})

      assert {:error, :no_matching_signature} =
               Webhook.verify(tampered_payload, sig_header, @secret)
    end

    test "returns error for nil header" do
      assert {:error, :missing_header} = Webhook.verify("{}", nil, @secret)
    end

    test "returns error for empty header" do
      assert {:error, :missing_header} = Webhook.verify("{}", "", @secret)
    end

    test "returns error for header without timestamp" do
      assert {:error, :invalid_header} = Webhook.verify("{}", "v1=abc123", @secret)
    end

    test "returns error for header without signature" do
      assert {:error, :invalid_header} = Webhook.verify("{}", "t=1234567890", @secret)
    end

    test "returns error for invalid JSON payload with valid signature" do
      payload = "not json"
      sig_header = Webhook.generate_test_signature(payload, @secret)

      assert {:error, _} = Webhook.verify(payload, sig_header, @secret)
    end

    test "supports secret rotation — accepts either secret in a list" do
      payload = ~s({"type":"test"})

      # Signed with old secret
      sig_header = Webhook.generate_test_signature(payload, @secret)

      # Verify with list of both old and new secret
      new_secret = "whsec_new_rotation_key"

      assert {:ok, _} = Webhook.verify(payload, sig_header, [@secret, new_secret])
    end

    test "accepts signature from new rotation key" do
      payload = ~s({"type":"test"})
      new_secret = "whsec_new_rotation_key"

      sig_header = Webhook.generate_test_signature(payload, new_secret)

      # Verify with list of both old and new secret
      assert {:ok, _} = Webhook.verify(payload, sig_header, [@secret, new_secret])
    end
  end

  describe "verify_signature/4" do
    test "returns timestamp on success without parsing JSON" do
      payload = ~s({"type":"test"})
      timestamp = System.system_time(:second)
      sig_header = Webhook.generate_test_signature(payload, @secret, timestamp: timestamp)

      assert {:ok, ^timestamp} = Webhook.verify_signature(payload, sig_header, @secret)
    end

    test "returns error for invalid signature header" do
      payload = ~s({"type":"test"})
      # Use current timestamp so it doesn't fail on timestamp check
      timestamp = System.system_time(:second)
      sig_header = "t=#{timestamp},v1=invalid_sig_that_is_definitely_wrong"

      assert {:error, :no_matching_signature} =
               Webhook.verify_signature(payload, sig_header, @secret)
    end
  end

  describe "generate_test_signature/3" do
    test "generates a header in the Stripe format" do
      payload = ~s({"type":"test"})
      sig = Webhook.generate_test_signature(payload, @secret)

      assert sig =~ "t="
      assert sig =~ "v1="
    end

    test "generated signature round-trips through verify" do
      payload = ~s({"id":"evt_round","type":"charge.succeeded"})
      sig = Webhook.generate_test_signature(payload, @secret)

      assert {:ok, %{"id" => "evt_round"}} = Webhook.verify(payload, sig, @secret)
    end

    test "respects custom timestamp option" do
      payload = ~s({"type":"test"})
      timestamp = 1_700_000_000
      sig = Webhook.generate_test_signature(payload, @secret, timestamp: timestamp)

      assert sig =~ "t=1700000000,"
    end
  end

  describe "webhook_secret/0" do
    test "returns the configured webhook secret" do
      # In test environment, this is set to "whsec_test_signing_key_for_webhook_verification"
      secret = Webhook.webhook_secret()
      assert secret != nil
      assert is_binary(secret) or is_list(secret)
    end
  end
end
