defmodule Mix.Tasks.Dhc.Discord.IdentityRecovery do
  @shortdoc "Operates separately authenticated Discord identity recovery cases"

  use Mix.Task

  alias Dhc.Discord.IdentityRecovery

  @impl Mix.Task
  def run(["open", manifest_path]) do
    Mix.Task.run("app.start")

    manifest_path
    |> read_envelope!()
    |> IdentityRecovery.open_signed(options())
    |> print!()
  end

  def run(["approve", manifest_path]) do
    Mix.Task.run("app.start")

    manifest_path
    |> read_envelope!()
    |> IdentityRecovery.approve_signed(options())
    |> print!()
  end

  def run(["complete", case_reference]) do
    Mix.Task.run("app.start")

    case_reference
    |> IdentityRecovery.complete(options().fingerprint_key)
    |> print!()
  end

  def run(_) do
    Mix.raise(
      "Expected: mix dhc.discord.identity_recovery open MANIFEST | approve MANIFEST | complete CASE_REFERENCE"
    )
  end

  defp options do
    %{
      manifest_key: required_env!("DISCORD_IDENTITY_RECOVERY_MANIFEST_KEY"),
      fingerprint_key: required_env!("DISCORD_SUBJECT_FINGERPRINT_KEY")
    }
  end

  defp read_envelope!(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, envelope} when is_map(envelope) <- Jason.decode(bytes) do
      envelope
    else
      _ -> Mix.raise("signed recovery manifest could not be read")
    end
  end

  defp required_env!(name), do: System.get_env(name) || Mix.raise("#{name} is required")

  defp print!({:ok, result}), do: Mix.shell().info(Jason.encode!(result, pretty: true))
  defp print!({:error, _reason}), do: Mix.raise("Discord identity recovery command failed safely")
end
