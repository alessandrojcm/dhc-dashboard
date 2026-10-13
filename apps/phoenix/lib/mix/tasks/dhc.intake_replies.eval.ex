defmodule Mix.Tasks.Dhc.IntakeReplies.Eval do
  @moduledoc """
  Evaluates TypeSafe Jev over a labelled Intake Reply CSV/TSV export.

      mix dhc.intake_replies.eval PATH

  The file has columns `email type answered`, `reply as pasted`, `intent`,
  and `money back yes/no`. Output contains aggregates only; the source file
  must stay under the gitignored `priv/intake_reply_eval/` directory.
  """

  @shortdoc "Evaluates Jev on labelled Intake Replies"

  use Mix.Task

  alias Dhc.BeginnersWorkshops.IntakeReplies.Eval

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")

    case Eval.run(path) do
      {:ok, report} -> print(report)
      {:error, reason} -> Mix.raise("Intake Reply eval failed: #{reason}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix dhc.intake_replies.eval PATH")

  defp print(report) do
    Mix.shell().info(
      "Intake Reply Jev eval: #{report.total} rows; #{report.empty_replies} empty after extraction"
    )

    money = report.money_back

    Mix.shell().info(
      "money_back agreement: #{money.agreement}/#{money.examples}" <>
        if(money.accuracy, do: " (#{percent(money.accuracy)})", else: " (n/a)")
    )

    for intent <- Dhc.BeginnersWorkshops.IntakeReplies.Classifier.intents() do
      item = report.by_intent[intent]
      Mix.shell().info("#{intent}: #{item.examples} examples")

      for threshold <- Enum.sort(Map.keys(item.thresholds)) do
        result = item.thresholds[threshold]

        Mix.shell().info(
          "  #{percent(threshold)}: #{result.actions_taken} actions, " <>
            "#{result.wrong_actions} wrong, #{result.coordinator} to coordinator"
        )
      end

      Mix.shell().info("  recommended: #{recommendation(item.recommended_threshold)}")
    end
  end

  defp recommendation(value) when is_number(value), do: percent(value)
  defp recommendation(value), do: value

  defp percent(value), do: "#{Float.round(value * 100, 1)}%"
end
