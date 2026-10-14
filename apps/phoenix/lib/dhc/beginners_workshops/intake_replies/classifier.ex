defmodule Dhc.BeginnersWorkshops.IntakeReplies.Classifier do
  @moduledoc """
  Classifies the intent in a person's extracted Intake Reply with TypeSafe's
  Jev System One API (ALE-410, ADR 0030).

  The caller supplies only `ReplyText.extract/1` output, the closed Intake
  Email type and the intents that can lead to a command for the person now.
  The person or Intake state is never added here. Requests and errors are
  deliberately not logged because the state contains personal correspondence.
  """

  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.TypeSafe.{Operations, SystemOneRequest}

  @model "jev-1.13.0"

  @intent_descriptions %{
    "cant_make_date" => "The person cannot attend this Beginners' Workshop date.",
    "leaving_waitlist" => "The person wants to leave the Beginners' Workshop Waitlist.",
    "wants_refund" => "The person is asking for a refund of money or a held workshop fee.",
    "wants_to_come_back" => "The person wants to come back onto the Waitlist.",
    "link_problem" => "The person's Intake link is lost, broken or not working.",
    "something_else" => "The reply does not clearly express one of the listed intents."
  }

  @type result :: %{
          intent: String.t(),
          probabilities: %{String.t() => number()},
          confidence: number(),
          money_back: number(),
          model: String.t()
        }

  @type error ::
          :not_configured
          | :invalid_input
          | :invalid_response
          | :transport
          | {:http_status, pos_integer()}

  @doc "Every intent the closed Classifier vocabulary recognises, in spec order."
  @spec intents() :: [String.t()]
  def intents,
    do:
      ~w(cant_make_date leaving_waitlist wants_refund wants_to_come_back link_problem something_else)

  @doc "Classifies extracted reply text against the supplied live allowed intents."
  @spec classify(String.t(), String.t(), [String.t() | atom()]) ::
          {:ok, result()} | {:error, error()}
  def classify(reply_text, email_type, allowed_intents) do
    with {:ok, intent_names} <- normalize_intents(allowed_intents),
         {:ok, email_type_words} <- email_type_words(email_type),
         {:ok, safe_reply_text} <- safe_reply_text(reply_text) do
      request(intent_names, email_type_words, safe_reply_text)
    end
  end

  @doc "Every intent an answered Intake Email type can lead to in an offline eval."
  @spec allowed_intents_for_email_type(String.t()) :: [String.t()]
  def allowed_intents_for_email_type(email_type) do
    if match?({:ok, %{kind: :action}}, EmailType.fetch(email_type)) do
      ~w(cant_make_date leaving_waitlist wants_refund wants_to_come_back link_problem)
    else
      ~w(leaving_waitlist wants_refund wants_to_come_back)
    end
  end

  defp request(intent_names, email_type_words, reply_text) do
    payload = %SystemOneRequest{
      model: Application.get_env(:dhc, :typesafe_model, @model),
      state: "Answered email: #{email_type_words}\n\nPerson's new reply:\n#{reply_text}",
      questions: questions(intent_names)
    }

    case Operations.systemone_v1_systemone_post(payload) do
      {:ok, body} -> decode_response(body, intent_names)
      {:error, :not_configured} -> {:error, :not_configured}
      {:error, {:http_status, status}} -> {:error, {:http_status, status}}
      {:error, _closed_error} -> {:error, :transport}
    end
  end

  defp questions(intent_names) do
    criteria =
      (intent_names ++ ["something_else"])
      |> Map.new(fn name -> {name, Map.fetch!(@intent_descriptions, name)} end)

    %{
      intent: %{
        type: "choice",
        instructions: "Which intent best describes what the person is asking for?",
        criteria: criteria
      },
      money_back: %{
        type: "noul",
        instructions: "Is the person asking for their money back?",
        criteria: %{
          "true" => "The person is asking for money to be returned.",
          "false" => "The person is not asking for money to be returned."
        }
      }
    }
  end

  defp decode_response(%{"model" => model, "answers" => answers}, intent_names)
       when is_binary(model) and is_map(answers) do
    valid_names = intent_names ++ ["something_else"]

    with true <- Regex.match?(~r/\Ajev-1\.\d+(?:\.\d+)?\z/, model),
         %{"type" => "choice", "choice" => intent, "probabilities" => probabilities} = choice
         when is_map(probabilities) <- Map.get(answers, "intent"),
         true <- intent in valid_names,
         true <- Map.keys(probabilities) |> Enum.sort() == Enum.sort(valid_names),
         true <- valid_probabilities?(probabilities),
         confidence when is_number(confidence) and confidence >= 0 and confidence <= 1 <-
           Map.get(choice, "confidence"),
         %{"type" => "noul", "noul" => money_back} <- Map.get(answers, "money_back"),
         true <- probability?(money_back) do
      {:ok,
       %{
         intent: intent,
         probabilities: probabilities,
         confidence: confidence,
         money_back: money_back,
         model: model
       }}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp decode_response(_body, _intent_names), do: {:error, :invalid_response}

  defp valid_probabilities?(probabilities) do
    Enum.all?(probabilities, fn {_intent, value} -> probability?(value) end)
  end

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp normalize_intents(intents) when is_list(intents) do
    normalized = Enum.map(intents, &normalize_intent/1)

    if intents != [] and Enum.all?(normalized, &is_binary/1) and
         length(Enum.uniq(normalized)) == length(normalized) and
         "something_else" not in normalized do
      {:ok, normalized}
    else
      {:error, :invalid_input}
    end
  end

  defp normalize_intents(_intents), do: {:error, :invalid_input}

  defp normalize_intent(intent) when is_atom(intent), do: normalize_intent(Atom.to_string(intent))

  defp normalize_intent(intent) when is_binary(intent) do
    if intent in intents() and intent != "something_else", do: intent
  end

  defp normalize_intent(_intent), do: nil

  defp email_type_words(email_type) when is_binary(email_type) do
    case EmailType.fetch(email_type) do
      {:ok, %{description: words}} -> {:ok, words}
      :error -> {:error, :invalid_input}
    end
  end

  defp email_type_words(_email_type), do: {:error, :invalid_input}

  defp safe_reply_text(text) when is_binary(text) do
    case Dhc.BeginnersWorkshops.IntakeReplies.ReplyText.extract(%{text: text, html: nil}) do
      {:ok, extracted} -> {:ok, extracted}
      :empty -> {:error, :invalid_input}
    end
  end

  defp safe_reply_text(_text), do: {:error, :invalid_input}
end
