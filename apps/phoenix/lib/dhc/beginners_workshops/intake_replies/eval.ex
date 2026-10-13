defmodule Dhc.BeginnersWorkshops.IntakeReplies.Eval do
  @moduledoc """
  Runs Jev over a hand-labelled, synthetic-or-approved CSV/TSV export without
  printing or retaining any reply text (ALE-410, ADR 0030).

  Required columns are `email type answered`, `reply as pasted`, `intent`, and
  `money back yes/no` (the final label is `yes` or `no`). Quoted cells may
  contain delimiters and multiple lines. This module returns aggregates only;
  row-level provider failures include the row number and closed error, never
  the cell contents.
  """

  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.BeginnersWorkshops.IntakeReplies.{Classifier, ReplyText}
  alias Dhc.Waitlist.Import.Sheet

  @headers %{
    "emailtypeanswered" => :email_type,
    "replyaspasted" => :reply,
    "intent" => :intent,
    "moneybackyesno" => :money_back
  }
  @thresholds Enum.map(50..95//5, &(&1 / 100))
  @actionable_intents ~w(cant_make_date leaving_waitlist wants_refund wants_to_come_back link_problem)

  @type sample :: %{
          intent: String.t(),
          money_back?: boolean(),
          result: Classifier.result() | nil
        }

  @doc "Reads a labelled file, classifies extracted replies and returns aggregate-only metrics."
  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(path, opts \\ []) do
    classifier = Keyword.get(opts, :classify, &Classifier.classify/3)

    with {:ok, contents} <- read_file(path),
         {:ok, rows} <- parse(contents),
         {:ok, samples} <- classify_rows(rows, classifier) do
      {:ok, summarize(samples)}
    end
  end

  defp read_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> {:error, "could not read the eval file"}
    end
  end

  defp read_file(_path), do: {:error, "the eval file path must be a string"}

  defp parse(contents) do
    delimiter =
      contents
      |> String.split(["\r\n", "\n", "\r"], parts: 2)
      |> List.first("")
      |> then(fn line -> if String.contains?(line, "\t"), do: ?\t, else: ?, end)

    with {:ok, [header | rows]} <- Sheet.records(contents, delimiter),
         {:ok, columns} <- columns(header),
         {:ok, labelled} <- Enum.with_index(rows, 2) |> read_rows(columns) do
      {:ok, labelled}
    else
      {:ok, []} -> {:error, "the eval file is empty"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp columns(header) do
    normalized = Enum.map(header, &normalize_header/1)

    Enum.reduce_while(@headers, {:ok, %{}}, fn {name, key}, {:ok, found} ->
      case Enum.find_index(normalized, &(&1 == name)) do
        nil -> {:halt, {:error, "the eval file is missing a required column"}}
        index -> {:cont, {:ok, Map.put(found, key, index)}}
      end
    end)
  end

  defp read_rows(rows, columns) do
    rows
    |> Enum.reduce_while({:ok, []}, fn {cells, row_number}, {:ok, parsed} ->
      case label_row(cells, row_number, columns) do
        {:ok, row} -> {:cont, {:ok, [row | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp label_row(cells, row_number, columns) do
    if Enum.any?(Map.values(columns), &(&1 >= length(cells))) do
      {:error, "row #{row_number} does not have all required columns"}
    else
      email_type = cell(cells, columns, :email_type)
      reply = cell(cells, columns, :reply)
      intent = cell(cells, columns, :intent)
      money_back = cell(cells, columns, :money_back) |> String.downcase()

      with {:ok, _type} <- EmailType.fetch(email_type),
           true <- intent in Classifier.intents(),
           {:ok, money_back?} <- money_back(money_back) do
        {:ok,
         %{
           email_type: email_type,
           reply: reply,
           intent: intent,
           money_back?: money_back?
         }}
      else
        _invalid -> {:error, "row #{row_number} has invalid labels"}
      end
    end
  end

  defp classify_rows(rows, classifier) when is_function(classifier, 3) do
    rows
    |> Enum.with_index(2)
    |> Enum.reduce_while({:ok, []}, fn {row, row_number}, {:ok, samples} ->
      case classify_row(row, row_number, classifier) do
        {:ok, sample} -> {:cont, {:ok, [sample | samples]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, samples} -> {:ok, Enum.reverse(samples)}
      error -> error
    end
  end

  defp classify_rows(_rows, _classifier),
    do: {:error, "the classifier must be a three-argument function"}

  defp classify_row(row, row_number, classifier) do
    case ReplyText.extract(%{text: row.reply, html: nil}) do
      :empty ->
        {:ok, Map.put(row, :result, nil)}

      {:ok, text} ->
        allowed = Classifier.allowed_intents_for_email_type(row.email_type)
        result = classifier.(text, row.email_type, allowed)
        classify_result(result, row, row_number)
    end
  end

  defp classify_result(
         {:ok, %{intent: intent, confidence: confidence, money_back: money_back} = result},
         row,
         row_number
       )
       when is_binary(intent) and is_number(confidence) and is_number(money_back) do
    if intent in Classifier.intents(),
      do: {:ok, Map.put(row, :result, result)},
      else: {:error, "row #{row_number} returned an invalid classification"}
  end

  defp classify_result({:error, reason}, _row, row_number),
    do: {:error, "row #{row_number} could not be classified (#{safe_reason(reason)})"}

  defp classify_result(_invalid, _row, row_number),
    do: {:error, "row #{row_number} returned an invalid classification"}

  defp summarize(samples) do
    total = length(samples)
    replies_with_results = Enum.filter(samples, &(not is_nil(&1.result)))
    money_back_examples = length(replies_with_results)

    agreement =
      Enum.count(replies_with_results, fn sample ->
        sample.result.money_back >= 0.5 == sample.money_back?
      end)

    %{
      total: total,
      empty_replies: total - money_back_examples,
      money_back: %{
        examples: money_back_examples,
        agreement: agreement,
        accuracy:
          if(money_back_examples == 0,
            do: nil,
            else: Float.round(agreement / money_back_examples, 4)
          )
      },
      by_intent: Map.new(Classifier.intents(), &{&1, intent_summary(&1, samples, total)})
    }
  end

  defp intent_summary(intent, samples, total) do
    examples = Enum.count(samples, &(&1.intent == intent))

    threshold_results =
      Map.new(@thresholds, fn threshold ->
        actions = actions_for_intent(intent, samples, threshold)

        wrong_actions = Enum.count(actions, &(&1.intent != intent))
        actions_taken = length(actions)

        {threshold,
         %{
           actions_taken: actions_taken,
           wrong_actions: wrong_actions,
           coordinator: total - actions_taken
         }}
      end)

    recommended_threshold = recommendation(intent, examples, threshold_results)

    %{
      examples: examples,
      thresholds: threshold_results,
      recommended_threshold: recommended_threshold
    }
  end

  defp recommendation("something_else", _examples, _thresholds), do: "stay off (not an action)"

  defp recommendation(_intent, examples, _thresholds) when examples < 20,
    do: "stay off (fewer than 20 examples)"

  defp recommendation(_intent, _examples, thresholds) do
    Enum.find_value(@thresholds, "stay off (no zero-error threshold)", fn threshold ->
      result = thresholds[threshold]
      if result.actions_taken > 0 and result.wrong_actions == 0, do: threshold
    end)
  end

  defp actions_for_intent(intent, samples, threshold) when intent in @actionable_intents do
    Enum.filter(samples, &action_for_intent?(&1, intent, threshold))
  end

  defp actions_for_intent(_intent, _samples, _threshold), do: []

  defp action_for_intent?(
         %{result: %{intent: predicted_intent, confidence: confidence}},
         expected_intent,
         threshold
       )
       when predicted_intent == expected_intent and confidence >= threshold,
       do: true

  defp action_for_intent?(_sample, _intent, _threshold), do: false

  defp cell(cells, columns, key), do: cells |> Enum.at(Map.fetch!(columns, key)) |> String.trim()

  defp normalize_header(header),
    do: header |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp money_back("yes"), do: {:ok, true}
  defp money_back("no"), do: {:ok, false}
  defp money_back(_other), do: :error

  defp safe_reason(reason)
       when reason in [:not_configured, :invalid_input, :invalid_response, :transport],
       do: Atom.to_string(reason)

  defp safe_reason({:http_status, status}) when is_integer(status), do: "http_status_#{status}"
  defp safe_reason(_other), do: "provider_error"
end
