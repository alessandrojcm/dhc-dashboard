defmodule Dhc.Discord.RosterPackage do
  @moduledoc false

  @aad "dhc-discord-roster-review-package-v1"

  def write(directory, capture_id, package, key) do
    with :ok <- File.mkdir_p(directory),
         {:ok, plaintext} <- Jason.encode(package),
         {:ok, encrypted} <- encrypt(plaintext, key),
         path <- Path.join(directory, "#{capture_id}.discord-roster.enc"),
         :ok <- File.write(path, encrypted, [:binary]) do
      {:ok, path}
    end
  end

  def delete(path), do: File.rm(path)

  defp encrypt(plaintext, key) do
    with {:ok, key} <- decode_key(key) do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, 16, true)

      {:ok, <<1, iv::binary, tag::binary, ciphertext::binary>>}
    end
  end

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
      _ -> {:error, :invalid_review_package_key}
    end
  end

  defp decode_key(_), do: {:error, :invalid_review_package_key}
end
