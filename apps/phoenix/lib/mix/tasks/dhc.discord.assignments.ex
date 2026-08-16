defmodule Mix.Tasks.Dhc.Discord.Assignments do
  @moduledoc """
  Stages Discord assignments and applies an independent review workflow.
  """

  @shortdoc "Stages and independently reviews controlled Discord assignments"

  use Mix.Task

  alias Dhc.Discord.Assignments

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["stage", roster_path, rows_path, preparer_principal_id] ->
        Assignments.stage(
          read_json!(roster_path, "roster"),
          read_json!(rows_path, "stage rows"),
          preparer_principal_id,
          options()
        )
        |> print!()

      ["review", capture_id, roster_path, reviewer_principal_id] ->
        Assignments.review_evidence(
          capture_id,
          read_json!(roster_path, "roster"),
          reviewer_principal_id
        )
        |> print!()

      ["apply-review", capture_id, rows_path, reviewer_principal_id] ->
        Assignments.apply_review(
          capture_id,
          read_json!(rows_path, "review rows"),
          reviewer_principal_id,
          options()
        )
        |> print!()

      ["withdraw", assignment_id, actor_principal_id, reason_code] ->
        Assignments.withdraw(assignment_id, actor_principal_id, reason_code) |> print!()

      ["supersede", assignment_id, roster_path, row_path, actor_principal_id] ->
        Assignments.supersede(
          assignment_id,
          read_json!(roster_path, "roster"),
          read_json!(row_path, "replacement row"),
          actor_principal_id,
          options()
        )
        |> print!()

      ["report", capture_id, roster_path] ->
        Assignments.report(capture_id, read_json!(roster_path, "roster"), options()) |> print!()

      _ ->
        Mix.raise("""
        Expected one of:
          mix dhc.discord.assignments stage ROSTER_JSON STAGE_ROWS_JSON PREPARER_PRINCIPAL_ID
          mix dhc.discord.assignments review CAPTURE_ID ROSTER_JSON REVIEWER_PRINCIPAL_ID
          mix dhc.discord.assignments apply-review CAPTURE_ID REVIEW_ROWS_JSON REVIEWER_PRINCIPAL_ID
          mix dhc.discord.assignments withdraw ASSIGNMENT_ID ACTOR_PRINCIPAL_ID REASON_CODE
          mix dhc.discord.assignments supersede ASSIGNMENT_ID ROSTER_JSON REPLACEMENT_ROW_JSON ACTOR_PRINCIPAL_ID
          mix dhc.discord.assignments report CAPTURE_ID ROSTER_JSON
        """)
    end
  end

  defp options do
    %{
      fingerprint_key: required_env!("DISCORD_SUBJECT_FINGERPRINT_KEY"),
      tool_revision: System.get_env("DISCORD_ASSIGNMENT_TOOL_REVISION", "unknown")
    }
  end

  defp read_json!(path, label) do
    with {:ok, bytes} <- File.read(path),
         {:ok, value} <- Jason.decode(bytes) do
      value
    else
      _ -> Mix.raise("#{label} JSON could not be read")
    end
  end

  defp required_env!(name), do: System.get_env(name) || Mix.raise("#{name} is required")

  defp print!({:ok, result}), do: Mix.shell().info(Jason.encode!(result, pretty: true))

  defp print!({:error, reason}),
    do: Mix.raise("Discord assignment command failed safely: #{inspect(reason)}")
end
