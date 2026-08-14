defmodule Dhc.Discord.SignedManifest do
  @moduledoc """
  Verifies exact JSON payloads wrapped in detached HMAC or Ed25519 signatures.

  Each envelope names its signing Principal, and every authorized operator has a
  distinct key. The signature covers both the signer and the original payload
  bytes, so one operator cannot claim another Principal or transplant a signature.
  """

  @domain_separator "dhc-discord-assignment-manifest-v2"

  def verify(envelope, keys) when is_map(envelope) and is_map(keys) do
    with true <- valid_keyring?(keys),
         true <-
           MapSet.new(Map.keys(envelope)) ==
             MapSet.new(~w(signer_principal_id payload signature)),
         signer when is_binary(signer) <- Map.get(envelope, "signer_principal_id"),
         {:ok, _} <- Ecto.UUID.cast(signer),
         key when is_binary(key) and key != "" <- Map.get(keys, signer),
         payload when is_binary(payload) <- Map.get(envelope, "payload"),
         signature when is_binary(signature) <- Map.get(envelope, "signature"),
         {:ok, payload_bytes} <- Base.url_decode64(payload, padding: false),
         {:ok, supplied_signature} <- Base.url_decode64(signature, padding: false),
         signed_bytes <- signed_bytes(signer, payload_bytes),
         expected_signature <- :crypto.mac(:hmac, :sha256, key, signed_bytes),
         true <- secure_compare(supplied_signature, expected_signature),
         {:ok, command} when is_map(command) <- Jason.decode(payload_bytes) do
      {:ok, command, digest(signed_bytes), signer}
    else
      _ -> {:error, :invalid_manifest_signature}
    end
  end

  def verify(_, _), do: {:error, :invalid_manifest_signature}

  @doc "Verifies an Ed25519 envelope without exposing the approver's private key."
  def verify_ed25519(envelope, public_key)
      when is_map(envelope) and is_binary(public_key) do
    with true <- MapSet.new(Map.keys(envelope)) == MapSet.new(~w(payload signature)),
         true <- byte_size(public_key) == 32,
         payload when is_binary(payload) <- Map.get(envelope, "payload"),
         signature when is_binary(signature) <- Map.get(envelope, "signature"),
         {:ok, payload_bytes} <- Base.url_decode64(payload, padding: false),
         {:ok, supplied_signature} <- Base.url_decode64(signature, padding: false),
         true <-
           :crypto.verify(
             :eddsa,
             :none,
             payload_bytes,
             supplied_signature,
             [public_key, :ed25519]
           ),
         {:ok, command} when is_map(command) <- Jason.decode(payload_bytes) do
      {:ok, command, digest(payload_bytes)}
    else
      _ -> {:error, :invalid_manifest_signature}
    end
  rescue
    ErlangError -> {:error, :invalid_manifest_signature}
  end

  def verify_ed25519(_, _), do: {:error, :invalid_manifest_signature}

  def read(path, keys) do
    with {:ok, bytes} <- File.read(path),
         {:ok, envelope} <- Jason.decode(bytes) do
      verify(envelope, keys)
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  def sign(command, signer, key)
      when is_map(command) and is_binary(signer) and is_binary(key) and key != "" do
    payload = Jason.encode!(command)
    signed_bytes = signed_bytes(signer, payload)

    %{
      "signer_principal_id" => signer,
      "payload" => Base.url_encode64(payload, padding: false),
      "signature" =>
        key
        |> then(&:crypto.mac(:hmac, :sha256, &1, signed_bytes))
        |> Base.url_encode64(padding: false)
    }
  end

  @doc "Signs an approval command with an actor-held Ed25519 private key."
  def sign_ed25519(command, private_key)
      when is_map(command) and is_binary(private_key) do
    payload = Jason.encode!(command)

    %{
      "payload" => Base.url_encode64(payload, padding: false),
      "signature" =>
        :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
        |> Base.url_encode64(padding: false)
    }
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_, _), do: false

  defp valid_keyring?(keys) do
    values = Map.values(keys)

    map_size(keys) > 0 and
      Enum.all?(keys, fn {principal_id, key} ->
        match?({:ok, _}, Ecto.UUID.cast(principal_id)) and is_binary(key) and key != ""
      end) and
      length(Enum.uniq(values)) == length(values)
  end

  defp signed_bytes(signer, payload), do: @domain_separator <> <<0>> <> signer <> <<0>> <> payload
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
