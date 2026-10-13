defmodule Dhc.Resend.Webhook do
  @moduledoc """
  Verifies Resend webhook deliveries (ALE-409). Resend signs every delivery
  with Svix: the `svix-signature` header carries one or more space-separated
  `v1,<base64 HMAC-SHA256>` signatures over `"<svix-id>.<svix-timestamp>.<raw
  body>"`, keyed by the base64 part of the `whsec_…` signing secret.

  The body must be the exact bytes Resend sent (`DhcWeb.CacheBodyReader`
  keeps them for `POST /api/webhooks/resend`). A timestamp more than five
  minutes from now is refused, so a captured delivery cannot be replayed.

  The secret is `RESEND_WEBHOOK_SIGNING_SECRET` (`config :dhc,
  :resend_webhook_secret`); a list holds several secrets during a rotation.
  """

  @tolerance_seconds 5 * 60
  @secret_prefix "whsec_"

  @type headers :: %{
          id: String.t() | nil,
          timestamp: String.t() | nil,
          signature: String.t() | nil
        }
  @type error ::
          :missing_header | :invalid_header | :timestamp_expired | :no_matching_signature

  @doc "The configured signing secret (or secrets), or `nil`."
  @spec webhook_secret() :: String.t() | [String.t()] | nil
  def webhook_secret, do: Application.get_env(:dhc, :resend_webhook_secret)

  @doc """
  Verifies `payload` against the Svix headers and returns the decoded event.
  `now` (Unix seconds) is the clock the timestamp is judged against.
  """
  @spec verify(binary(), headers(), String.t() | [String.t()], integer()) ::
          {:ok, map()} | {:error, error() | :invalid_payload}
  def verify(payload, headers, secret, now \\ System.system_time(:second))
      when is_binary(payload) do
    with {:ok, id, timestamp, signatures} <- parse(headers),
         :ok <- fresh(timestamp, now),
         :ok <- matching(payload, id, timestamp, signatures, List.wrap(secret)) do
      decode(payload)
    end
  end

  @doc """
  Signs `payload` the way Resend does, returning the `svix-signature` header
  value. Used by tests and local tooling to produce deliveries.
  """
  @spec sign(binary(), String.t(), integer(), String.t()) :: String.t()
  def sign(payload, id, timestamp, secret)
      when is_binary(payload) and is_binary(id) and is_integer(timestamp) do
    "v1," <> signature(payload, id, Integer.to_string(timestamp), secret)
  end

  defp parse(%{id: id, timestamp: timestamp, signature: signature})
       when is_binary(id) and is_binary(timestamp) and is_binary(signature) do
    signatures =
      for part <- String.split(signature, " ", trim: true),
          ["v1", value] <- [String.split(part, ",", parts: 2)],
          do: value

    case {Integer.parse(timestamp), signatures} do
      {{seconds, ""}, [_ | _]} -> {:ok, id, seconds, signatures}
      _malformed -> {:error, :invalid_header}
    end
  end

  defp parse(_headers), do: {:error, :missing_header}

  defp fresh(timestamp, now) when abs(now - timestamp) <= @tolerance_seconds, do: :ok
  defp fresh(_timestamp, _now), do: {:error, :timestamp_expired}

  defp matching(payload, id, timestamp, signatures, secrets) do
    timestamp = Integer.to_string(timestamp)

    expected =
      for secret <- secrets,
          is_binary(secret),
          secret != "",
          do: signature(payload, id, timestamp, secret)

    if Enum.any?(expected, fn sig ->
         Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, sig))
       end),
       do: :ok,
       else: {:error, :no_matching_signature}
  end

  defp signature(payload, id, timestamp, secret) do
    :hmac
    |> :crypto.mac(:sha256, key(secret), "#{id}.#{timestamp}.#{payload}")
    |> Base.encode64()
  end

  # The key is the base64 after `whsec_`; a secret that is not base64 is
  # used as raw bytes, which can never match a real delivery.
  defp key(@secret_prefix <> encoded), do: key(encoded)

  defp key(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} -> key
      :error -> encoded
    end
  end

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = event} -> {:ok, event}
      _not_an_object -> {:error, :invalid_payload}
    end
  end
end
