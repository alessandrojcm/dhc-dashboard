defmodule Mix.Tasks.Dhc.Discord.IdentityRecovery do
  @shortdoc "Operates separately authenticated Discord identity recovery cases"

  use Mix.Task

  alias Dhc.Discord.IdentityRecovery

  @impl Mix.Task
  def run(["open", manifest_path, operator_proof_path]) do
    Mix.Task.run("app.start")

    IdentityRecovery.open_signed(
      read_envelope!(manifest_path),
      read_envelope!(operator_proof_path),
      open_options()
    )
    |> print!()
  end

  def run(["approve", manifest_path]) do
    Mix.Task.run("app.start")

    manifest_path
    |> read_envelope!()
    |> IdentityRecovery.approve_signed(approval_options())
    |> print!()
  end

  def run(["complete", case_reference]) do
    Mix.Task.run("app.start")

    case_reference
    |> IdentityRecovery.complete(required_env!("DISCORD_SUBJECT_FINGERPRINT_KEY"))
    |> print!()
  end

  def run(_) do
    Mix.raise(
      "Expected: mix dhc.discord.identity_recovery open MANIFEST OPERATOR_PROOF | approve MANIFEST | complete CASE_REFERENCE"
    )
  end

  defp open_options do
    %{
      manifest_keys: required_keyring!("DISCORD_IDENTITY_RECOVERY_MANIFEST_KEYS"),
      operator_proof_keys: required_keyring!("DISCORD_IDENTITY_RECOVERY_OPERATOR_PROOF_KEYS"),
      fingerprint_key: required_env!("DISCORD_SUBJECT_FINGERPRINT_KEY")
    }
  end

  defp approval_options,
    do: %{manifest_keys: required_keyring!("DISCORD_IDENTITY_RECOVERY_MANIFEST_KEYS")}

  defp read_envelope!(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, envelope} when is_map(envelope) <- Jason.decode(bytes) do
      envelope
    else
      _ -> Mix.raise("signed recovery manifest could not be read")
    end
  end

  defp required_env!(name), do: System.get_env(name) || Mix.raise("#{name} is required")

  defp required_keyring!(name) do
    with encoded when is_binary(encoded) <- System.get_env(name),
         {:ok, keys} when is_map(keys) and map_size(keys) > 0 <- Jason.decode(encoded),
         true <-
           Enum.all?(keys, fn {principal_id, key} ->
             match?({:ok, _}, Ecto.UUID.cast(principal_id)) and is_binary(key) and key != ""
           end),
         true <- Map.values(keys) |> Enum.uniq() |> length() == map_size(keys) do
      keys
    else
      _ -> Mix.raise("#{name} must be a JSON object of Principal UUIDs to distinct signing keys")
    end
  end

  defp print!({:ok, result}), do: Mix.shell().info(Jason.encode!(result, pretty: true))
  defp print!({:error, _reason}), do: Mix.raise("Discord identity recovery command failed safely")
end
