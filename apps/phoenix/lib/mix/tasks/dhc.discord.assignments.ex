defmodule Mix.Tasks.Dhc.Discord.Assignments do
  @shortdoc "Stages and independently reviews controlled Discord assignments"

  use Mix.Task

  alias Dhc.Discord.Assignments

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["stage", manifest_path, package_path] ->
        manifest_path
        |> read_envelope!()
        |> Assignments.stage_signed(options(package_path))
        |> print!()

      ["review", capture_id, reviewer_principal_id, package_path] ->
        Assignments.review_evidence(capture_id, reviewer_principal_id, options(package_path))
        |> print!()

      ["apply-review", manifest_path] ->
        manifest_path
        |> read_envelope!()
        |> Assignments.apply_review_signed(options())
        |> print!()

      ["withdraw", manifest_path] ->
        manifest_path |> read_envelope!() |> Assignments.withdraw_signed(options()) |> print!()

      ["supersede", manifest_path, package_path] ->
        manifest_path
        |> read_envelope!()
        |> Assignments.supersede_signed(options(package_path))
        |> print!()

      ["report", capture_id, package_path] ->
        Assignments.report(capture_id, options(package_path)) |> print!()

      _ ->
        Mix.raise("""
        Expected one of:
          mix dhc.discord.assignments stage MANIFEST PACKAGE
          mix dhc.discord.assignments review CAPTURE_ID REVIEWER_PRINCIPAL_ID PACKAGE
          mix dhc.discord.assignments apply-review MANIFEST
          mix dhc.discord.assignments withdraw MANIFEST
          mix dhc.discord.assignments supersede MANIFEST PACKAGE
          mix dhc.discord.assignments report CAPTURE_ID PACKAGE
        """)
    end
  end

  defp options(package_path \\ nil) do
    %{
      manifest_keys: required_manifest_keys!(),
      fingerprint_key: required_env!("DISCORD_SUBJECT_FINGERPRINT_KEY"),
      package_key: System.get_env("DISCORD_ROSTER_PACKAGE_KEY"),
      package_path: package_path,
      tool_revision: System.get_env("DISCORD_ASSIGNMENT_TOOL_REVISION", "unknown")
    }
  end

  defp read_envelope!(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, envelope} when is_map(envelope) <- Jason.decode(bytes) do
      envelope
    else
      _ -> Mix.raise("signed manifest could not be read")
    end
  end

  defp required_env!(name), do: System.get_env(name) || Mix.raise("#{name} is required")

  defp required_manifest_keys! do
    with encoded when is_binary(encoded) <- System.get_env("DISCORD_ASSIGNMENT_MANIFEST_KEYS"),
         {:ok, keys} when is_map(keys) and map_size(keys) > 0 <- Jason.decode(encoded),
         true <-
           Enum.all?(keys, fn {principal_id, key} ->
             match?({:ok, _}, Ecto.UUID.cast(principal_id)) and is_binary(key) and key != ""
           end),
         true <- Map.values(keys) |> Enum.uniq() |> length() == map_size(keys) do
      keys
    else
      _ ->
        Mix.raise(
          "DISCORD_ASSIGNMENT_MANIFEST_KEYS must be a JSON object of Principal UUIDs to distinct signing keys"
        )
    end
  end

  defp print!({:ok, result}), do: Mix.shell().info(Jason.encode!(result, pretty: true))

  defp print!({:error, reason}),
    do: Mix.raise("Discord assignment command failed safely: #{inspect(reason)}")
end
