defmodule Dhc.Email.ApiClientTest do
  use ExUnit.Case, async: true

  alias Dhc.Email.ApiClient
  alias Swoosh.Email

  @job_id 42

  # Swoosh's first-party adapters hard-code their HTTP request headers, so the
  # repo ships a tiny api_client wrapper that lifts the :idempotency_key
  # provider option onto every provider call as an Idempotency-Key HTTP header
  # (ADR 0021). These tests pin that contract.

  defp email_with(opts) do
    email = %Email{} |> Email.to("user@example.com") |> Email.from("dev@dhc.local")

    Enum.reduce(opts, email, fn {key, value}, acc ->
      Email.put_provider_option(acc, key, value)
    end)
  end

  describe "idempotency_header/2" do
    test "lifts the :idempotency_key provider option into an HTTP header" do
      headers =
        ApiClient.idempotency_header([], email_with(idempotency_key: "oban-#{@job_id}"))

      assert {"Idempotency-Key", "oban-#{@job_id}"} in headers
    end

    test "prepends the header without disturbing adapter-supplied headers" do
      base_headers = [{"Content-Type", "application/json"}, {"Authorization", "Bearer sk"}]

      headers =
        ApiClient.idempotency_header(base_headers, email_with(idempotency_key: "oban-7"))

      assert headers == [
               {"Idempotency-Key", "oban-7"},
               {"Content-Type", "application/json"},
               {"Authorization", "Bearer sk"}
             ]
    end

    test "returns the original headers when no idempotency option is set" do
      base_headers = [{"Content-Type", "application/json"}]

      assert ApiClient.idempotency_header(base_headers, email_with([])) == base_headers
    end
  end

end
