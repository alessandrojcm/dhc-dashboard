defmodule Dhc.BeginnersWorkshops.IntakeEmails.Renderer do
  @moduledoc """
  Fills an Intake Email template (ALE-377).

  The body is a Tiptap document in the Member Announcement closed vocabulary
  (`Dhc.Email.RichText`) plus an inline `placeholder` node
  (`%{"type" => "placeholder", "attrs" => %{"name" => "firstName"}}`). It
  renders **without per-element inline styles**: the result travels as one
  Resend variable (`MESSAGE_HTML`), and the Email Kind's wrapper styles it.
  Every text node is escaped, and placeholder values are substituted
  HTML-escaped, because `firstName` comes from public registration.

  The subject is plain text with `{{placeholder}}` tokens; it is sent as the
  email subject, so its values are not escaped.

  Each email type accepts only its own placeholders (`EmailType`). Anything
  else is refused, so a saved template can always be filled.

  ## The 2,000-character measure

  Resend caps a string variable at 2,000 characters. `measure/2` renders the
  body with every placeholder replaced by `"x"` repeated to its maximum
  length and counts UTF-16 code units, the unit JavaScript's `String#length`
  uses, so the dashboard counter can apply the same algorithm. Both sides
  check themselves against
  `packages/email-templates/fixtures/intake-email-measure.json`.
  """

  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.Email.RichText

  @limit 2_000
  @subject_max 200
  @filler "x"
  @token ~r/\{\{(.*?)\}\}/

  @type values :: %{optional(String.t()) => String.t()}
  @type error ::
          {:placeholder_not_allowed, [String.t()]}
          | {:missing_values, [String.t()]}
          | {:invalid_body, String.t()}

  @doc "Resend's per-variable limit, which the body measure is checked against."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  The rendered body for a type with its placeholders filled from `values`.
  """
  @spec render_body(EmailType.id(), term(), values()) :: {:ok, String.t()} | {:error, error()}
  def render_body(type, body, values) do
    %{placeholders: allowed} = EmailType.fetch!(type)
    names = RichText.placeholder_names(body)

    with :ok <- allowed(names, allowed),
         :ok <- present(names, values) do
      render(body, &Map.fetch!(values, &1))
    end
  end

  @doc """
  The worst-case body: every placeholder at its maximum length, its length in
  UTF-16 code units, and whether it fits the limit.
  """
  @spec measure(EmailType.id(), term()) ::
          {:ok, %{html: String.t(), length: non_neg_integer(), fits?: boolean()}}
          | {:error, error()}
  def measure(type, body) do
    %{placeholders: allowed} = EmailType.fetch!(type)
    maxima = EmailType.maxima()

    with :ok <- allowed(RichText.placeholder_names(body), allowed),
         {:ok, html} <- render(body, &String.duplicate(@filler, Map.fetch!(maxima, &1))) do
      length = utf16_length(html)
      {:ok, %{html: html, length: length, fits?: length <= @limit}}
    end
  end

  @doc "The subject for a type with its `{{placeholder}}` tokens filled."
  @spec render_subject(EmailType.id(), String.t(), values()) ::
          {:ok, String.t()} | {:error, error()}
  def render_subject(type, subject, values) when is_binary(subject) do
    %{placeholders: allowed} = EmailType.fetch!(type)
    names = subject_tokens(subject)

    with :ok <- allowed(names, allowed),
         :ok <- present(names, values) do
      {:ok, Regex.replace(@token, subject, fn _match, name -> Map.fetch!(values, name) end)}
    end
  end

  @doc """
  The save check: the subject and body use only the type's placeholders, the
  subject is one non-blank line of at most #{@subject_max} characters, and the
  worst-case body fits the limit.
  """
  @spec validate(EmailType.id(), term(), term()) ::
          :ok | {:error, [{:subject | :body, String.t()}]}
  def validate(type, subject, body) do
    case subject_errors(type, subject) ++ body_errors(type, body) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc "Counts a string the way JavaScript's `String#length` does."
  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(string) when is_binary(string) do
    string |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)
  end

  # ── Checks ───────────────────────────────────────────────────────────

  defp subject_errors(type, subject) when is_binary(subject) do
    cond do
      String.trim(subject) == "" ->
        [{:subject, "can't be blank"}]

      String.contains?(subject, ["\r", "\n"]) ->
        [{:subject, "must be a single line"}]

      String.length(subject) > @subject_max ->
        [{:subject, "must be at most #{@subject_max} characters"}]

      true ->
        %{placeholders: allowed} = EmailType.fetch!(type)

        case allowed(subject_tokens(subject), allowed) do
          :ok ->
            []

          {:error, {:placeholder_not_allowed, names}} ->
            Enum.map(names, &{:subject, cant_fill(&1)})
        end
    end
  end

  defp subject_errors(_type, _subject), do: [{:subject, "must be text"}]

  defp body_errors(type, body) do
    case measure(type, body) do
      {:ok, %{fits?: true}} ->
        []

      {:ok, %{length: length}} ->
        [
          {:body,
           "is #{length} characters with every placeholder at its longest; the limit is #{@limit}"}
        ]

      {:error, {:placeholder_not_allowed, names}} ->
        Enum.map(names, &{:body, cant_fill(&1)})

      {:error, {:invalid_body, message}} ->
        [{:body, message}]
    end
  end

  defp cant_fill(name), do: "uses {{#{name}}}, which this email can't fill"

  defp allowed(names, allowed) do
    case Enum.reject(names, &(&1 in allowed)) do
      [] -> :ok
      refused -> {:error, {:placeholder_not_allowed, refused}}
    end
  end

  defp present(names, values) do
    case Enum.reject(names, &is_binary(Map.get(values, &1))) do
      [] -> :ok
      missing -> {:error, {:missing_values, missing}}
    end
  end

  defp subject_tokens(subject) do
    @token |> Regex.scan(subject, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
  end

  defp render(body, value_for) do
    case RichText.render(body, placeholder: &{:ok, value_for.(&1)}) do
      {:ok, %{html: html}} -> {:ok, html}
      {:error, message} -> {:error, {:invalid_body, message}}
    end
  end
end
