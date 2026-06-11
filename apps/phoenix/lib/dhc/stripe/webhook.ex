defmodule Dhc.Stripe.Webhook do
  @moduledoc """
  Stripe webhook signature verification.

  Verifies the `Stripe-Signature` header using HMAC-SHA256
  and protects against replay attacks via timestamp tolerance.

  ## Algorithm

  1. Parse the `Stripe-Signature` header to extract the timestamp (`t`)
     and one or more `v1` signatures.
  2. Construct the signed payload: `<timestamp_string>.<raw_request_body>`.
  3. Compute HMAC-SHA256 of the signed payload using the webhook secret.
  4. Compare the expected signature against each `v1` signature using
     constant-time comparison (`Plug.Crypto.secure_compare/2`).
  5. Reject if the timestamp is older than the tolerance window (default 300s).

  ## Usage

      {:ok, event} = Dhc.Stripe.Webhook.verify(raw_body, sig_header, secret)
      # => {:ok, %{"type" => "charge.succeeded", "data" => %{...}}}

  ## Testing

  Use `generate_test_signature/3` to create valid Stripe-Signature headers
  for test requests without needing the Stripe CLI.
  """

  @default_tolerance 300

  @doc """
  Verify a Stripe webhook signature and return the parsed event map.

  Returns `{:ok, map}` when the signature is valid and the payload parses
  as JSON. Returns `{:error, reason}` on any failure.

  ## Options

    * `:tolerance` — maximum age of the timestamp in seconds (default 300).
      Set to `0` to skip the recency check (not recommended in production).
  """
  @spec verify(binary(), String.t() | nil, String.t() | [String.t()], keyword()) ::
          {:ok, map()} | {:error, atom()}
  def verify(payload, sig_header, secret, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)

    with {:ok, timestamp_str, signatures} <- parse_header(sig_header),
         {:ok, timestamp} <- parse_timestamp(timestamp_str),
         :ok <- check_tolerance(timestamp, tolerance),
         :ok <- check_signatures(signatures, timestamp_str, payload, secret) do
      Jason.decode(payload)
    end
  end

  @doc """
  Verify signature only (no JSON parsing).

  Returns `{:ok, timestamp}` when the signature is valid, or
  `{:error, reason}` on failure. Use this when you want to validate
  the signature in the controller but pass the raw payload to a worker.
  """
  @spec verify_signature(binary(), String.t() | nil, String.t() | [String.t()], keyword()) ::
          {:ok, integer()} | {:error, atom()}
  def verify_signature(payload, sig_header, secret, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)

    with {:ok, timestamp_str, signatures} <- parse_header(sig_header),
         {:ok, timestamp} <- parse_timestamp(timestamp_str),
         :ok <- check_tolerance(timestamp, tolerance),
         :ok <- check_signatures(signatures, timestamp_str, payload, secret) do
      {:ok, timestamp}
    end
  end

  @doc """
  Generate a test Stripe-Signature header value.

  Useful for integration tests. Produces the same format Stripe sends:
  `t=<timestamp>,v1=<hex_signature>`.

  ## Options

    * `:timestamp` — Unix timestamp (default: current time)
  """
  @spec generate_test_signature(binary(), String.t(), keyword()) :: String.t()
  def generate_test_signature(payload, secret, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))
    timestamp_str = Integer.to_string(timestamp)
    signature = compute_signature(payload, timestamp_str, secret)
    "t=#{timestamp_str},v1=#{signature}"
  end

  # ── Header parsing ──────────────────────────────────────────────────

  defp parse_header(nil), do: {:error, :missing_header}
  defp parse_header(""), do: {:error, :missing_header}

  defp parse_header(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(fn part ->
        case String.split(part, "=", parts: 2) do
          [k, v] -> {String.trim(k), String.trim(v)}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    timestamp =
      Enum.find_value(parts, fn
        {"t", v} -> v
        _ -> nil
      end)

    signatures = for {"v1", v} <- parts, do: v

    cond do
      is_nil(timestamp) -> {:error, :invalid_header}
      signatures == [] -> {:error, :invalid_header}
      true -> {:ok, timestamp, signatures}
    end
  end

  defp parse_timestamp(timestamp_str) do
    case Integer.parse(timestamp_str) do
      {ts, ""} -> {:ok, ts}
      _ -> {:error, :invalid_header}
    end
  end

  # ── Tolerance check (replay protection) ──────────────────────────────

  defp check_tolerance(_timestamp, 0), do: :ok

  defp check_tolerance(timestamp, tolerance) do
    now = System.system_time(:second)

    if timestamp >= now - tolerance do
      :ok
    else
      {:error, :timestamp_expired}
    end
  end

  # ── Signature checking ───────────────────────────────────────────────

  defp check_signatures(signatures, timestamp_str, payload, secret) do
    secrets = List.wrap(secret)
    signed_payload = "#{timestamp_str}.#{payload}"

    matched? =
      Enum.any?(secrets, fn s ->
        expected = compute_signature_from_signed(signed_payload, s)

        Enum.any?(signatures, fn sig ->
          Plug.Crypto.secure_compare(sig, expected)
        end)
      end)

    if matched?, do: :ok, else: {:error, :no_matching_signature}
  end

  defp compute_signature(payload, timestamp_str, secret) do
    "#{timestamp_str}.#{payload}"
    |> compute_signature_from_signed(secret)
  end

  defp compute_signature_from_signed(signed_payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, signed_payload)
    |> Base.encode16(case: :lower)
  end

  # ── Config accessor ──────────────────────────────────────────────────

  @doc """
  Returns the Stripe webhook signing secret from app config.

  Supports a single secret (string) or a list of secrets for
  rotation periods. Falls back to the `STRIPE_WEBHOOK_SIGNING_SECRET`
  environment variable.
  """
  @spec webhook_secret() :: String.t() | [String.t()] | nil
  def webhook_secret do
    Application.get_env(:dhc, :stripe_webhook_secret) ||
      System.get_env("STRIPE_WEBHOOK_SIGNING_SECRET")
  end
end
