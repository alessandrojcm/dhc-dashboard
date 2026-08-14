defmodule Dhc.Discord.SignedManifest do
  @moduledoc """
  Verifies an exact JSON payload wrapped in a detached HMAC signature.

  The envelope is `{\"payload\": base64url, \"signature\": base64url}`. The
  signature covers the decoded payload bytes, so parsing or key ordering cannot
  change the signed command.
  """

  def verify(envelope, key) when is_map(envelope) and is_binary(key) and key != "" do
    with payload when is_binary(payload) <- Map.get(envelope, "payload"),
         signature when is_binary(signature) <- Map.get(envelope, "signature"),
         {:ok, payload_bytes} <- Base.url_decode64(payload, padding: false),
         {:ok, supplied_signature} <- Base.url_decode64(signature, padding: false),
         expected_signature <- :crypto.mac(:hmac, :sha256, key, payload_bytes),
         true <- secure_compare(supplied_signature, expected_signature),
         {:ok, command} when is_map(command) <- Jason.decode(payload_bytes) do
      {:ok, command, digest(payload_bytes)}
    else
      _ -> {:error, :invalid_manifest_signature}
    end
  end

  def verify(_, _), do: {:error, :invalid_manifest_signature}

  def read(path, key) do
    with {:ok, bytes} <- File.read(path),
         {:ok, envelope} <- Jason.decode(bytes) do
      verify(envelope, key)
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  def sign(command, key) when is_map(command) and is_binary(key) and key != "" do
    payload = Jason.encode!(command)

    %{
      "payload" => Base.url_encode64(payload, padding: false),
      "signature" =>
        key
        |> then(&:crypto.mac(:hmac, :sha256, &1, payload))
        |> Base.url_encode64(padding: false)
    }
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_, _), do: false

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
