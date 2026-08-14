defmodule Dhc.Discord.RosterPackage do
  @moduledoc false

  import Bitwise

  @aad "dhc-discord-roster-review-package-v1"
  @final_suffix ".discord-roster.enc"
  @temporary_suffix ".discord-roster.tmp"

  def write(directory, capture_id, package, key) do
    path = Path.join(directory, capture_id <> @final_suffix)

    temporary_path =
      Path.join(
        directory,
        ".#{capture_id}.#{System.unique_integer([:positive])}#{@temporary_suffix}"
      )

    with :ok <- ensure_directory(directory),
         :ok <- ensure_absent(path),
         {:ok, plaintext} <- Jason.encode(package),
         {:ok, encrypted} <- encrypt(plaintext, key),
         :ok <- write_restricted(temporary_path, encrypted) do
      publish_without_overwrite(temporary_path, path)
    else
      {:error, reason} -> cleanup_failed_write([temporary_path], reason)
    end
  end

  def read(path, key) do
    with {:ok, encrypted} <- File.read(path),
         {:ok, plaintext} <- decrypt(encrypted, key),
         {:ok, package} <- Jason.decode(plaintext) do
      {:ok, package}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_review_package}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete(path), do: File.rm(path)

  def reconcile_orphans(directory, capture_exists?) when is_function(capture_exists?, 1) do
    case File.lstat(directory) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        with :ok <- verify_mode(directory, :directory, 0o700),
             {:ok, entries} <- File.ls(directory) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            path = Path.join(directory, entry)

            case reconcile_entry(path, entry, capture_exists?) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
        end

      {:error, reason} ->
        {:error, {:package_directory_unavailable, reason}}
    end
  end

  defp reconcile_entry(path, entry, capture_exists?) do
    cond do
      String.ends_with?(entry, @temporary_suffix) ->
        remove_or_error(path)

      String.ends_with?(entry, @final_suffix) ->
        capture_id = String.trim_trailing(entry, @final_suffix)

        with {:ok, capture_id} <- Ecto.UUID.cast(capture_id) do
          if capture_exists?.(capture_id) do
            verify_mode(path, :regular, 0o600)
          else
            remove_or_error(path)
          end
        else
          :error -> {:error, :unexpected_roster_package_name}
        end

      true ->
        :ok
    end
  end

  defp ensure_directory(directory) do
    case File.lstat(directory) do
      {:ok, _stat} ->
        verify_mode(directory, :directory, 0o700)

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(directory),
             :ok <- File.chmod(directory, 0o700),
             :ok <- verify_mode(directory, :directory, 0o700) do
          :ok
        end

      {:error, reason} ->
        {:error, {:package_directory_unavailable, reason}}
    end
  end

  defp ensure_absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :review_package_already_exists}
      {:error, reason} -> {:error, {:review_package_unavailable, reason}}
    end
  end

  defp write_restricted(path, encrypted) do
    with :ok <- File.write(path, encrypted, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600),
         :ok <- verify_mode(path, :regular, 0o600) do
      :ok
    end
  end

  defp publish_without_overwrite(temporary_path, path) do
    case File.ln(temporary_path, path) do
      :ok ->
        result =
          with :ok <- File.rm(temporary_path),
               :ok <- verify_mode(path, :regular, 0o600) do
            {:ok, path}
          end

        case result do
          {:ok, _path} = ok -> ok
          {:error, reason} -> cleanup_failed_write([temporary_path, path], reason)
        end

      {:error, :eexist} ->
        cleanup_failed_write([temporary_path], :review_package_already_exists)

      {:error, reason} ->
        cleanup_failed_write(
          [temporary_path],
          {:review_package_publish_failed, reason}
        )
    end
  end

  defp verify_mode(path, expected_type, expected_mode) do
    with {:ok, current_uid} <- current_uid() do
      case File.lstat(path) do
        {:ok, %{type: ^expected_type, mode: mode, uid: ^current_uid}}
        when (mode &&& 0o777) == expected_mode ->
          :ok

        {:ok, %{uid: uid}} when uid != current_uid ->
          {:error, {:unsafe_package_owner, uid}}

        {:ok, %{type: type, mode: mode}} ->
          {:error, {:unsafe_package_permissions, type, mode &&& 0o777}}

        {:error, reason} ->
          {:error, {:package_stat_failed, reason}}
      end
    end
  end

  defp current_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case output |> String.trim() |> Integer.parse() do
          {uid, ""} -> {:ok, uid}
          _invalid -> {:error, :package_owner_unavailable}
        end

      {_output, _status} ->
        {:error, :package_owner_unavailable}
    end
  end

  defp cleanup_failed_write(paths, original_reason) do
    cleanup_error =
      Enum.reduce(paths, nil, fn path, first_error ->
        case File.rm(path) do
          :ok -> first_error
          {:error, :enoent} -> first_error
          {:error, reason} -> first_error || reason
        end
      end)

    if cleanup_error,
      do: {:error, {:package_cleanup_failed, original_reason, cleanup_error}},
      else: {:error, original_reason}
  end

  defp remove_or_error(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:package_cleanup_failed, reason}}
    end
  end

  defp encrypt(plaintext, key) do
    with {:ok, key} <- decode_key(key) do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, 16, true)

      {:ok, <<1, iv::binary, tag::binary, ciphertext::binary>>}
    end
  end

  defp decrypt(<<1, iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>, key) do
    with {:ok, key} <- decode_key(key) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             @aad,
             tag,
             false
           ) do
        :error -> {:error, :invalid_review_package}
        plaintext -> {:ok, plaintext}
      end
    end
  end

  defp decrypt(_, _), do: {:error, :invalid_review_package}

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
      _ -> {:error, :invalid_review_package_key}
    end
  end

  defp decode_key(_), do: {:error, :invalid_review_package_key}
end
