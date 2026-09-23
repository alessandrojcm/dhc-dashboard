defmodule Dhc.TrainingAnnouncements.Copy do
  @moduledoc """
  Pure renderer for Training Announcement copy (ALE-322).

  Editable copy uses a small, non-programmable token vocabulary, validated
  before anything is saved or previewed:

  | Token          | Renders                                              | Allowed in              |
  | ---            | ---                                                  | ---                     |
  | `{{title}}`    | the resolved Training Announcement title           | announcement messages   |
  | `{{date}}`     | the occurrence date, e.g. `Thursday 25 September`  | everywhere              |
  | `{{weekday}}`  | the occurrence weekday, e.g. `Thursday`            | announcements           |
  | `{{holidayName}}` | the bank-holiday name                            | Holiday Announcements   |

  A `{{title}}` inside a title template is rejected: the resolved title is
  what the token means, so a self-reference can never render. Free text
  renders literally — a typed `@everyone` never pings anyone. Whether
  anything pings is decided exclusively by the `@everyone` toggle: on render
  the system prepends `@everyone` plus a newline, and the delivery path sets
  `allowed_mentions` from the same toggle.

  The resolved title doubles as the Discord thread name, so titles are
  limited to 100 characters and messages to 2,000 characters *after*
  rendering, matching the delivery validation in ALE-309.

  Glossary (`CONTEXT.md`): "Free text is always posted literally; only the
  explicit `@everyone` setting can make anything ping."
  """

  @message_max 2_000
  @title_max 100

  @message_tokens ~w(title date weekday)
  @title_tokens ~w(date weekday)
  @holiday_tokens ~w(holidayName date)

  @token_re ~r/\{\{\s*([A-Za-z]+)\s*\}\}/

  @type bindings :: %{optional(:title) => String.t(), optional(:date) => Date.t()}

  @doc "Formats a date as e.g. `Thursday 25 September` (Europe/Dublin civil date)."
  @spec format_date(Date.t()) :: String.t()
  def format_date(%Date{} = date) do
    "#{format_weekday(date)} #{date.day} #{month_name(date.month)}"
  end

  @doc "Formats a date's weekday as e.g. `Thursday`."
  @spec format_weekday(Date.t()) :: String.t()
  def format_weekday(%Date{} = date) do
    case Date.day_of_week(date) do
      1 -> "Monday"
      2 -> "Tuesday"
      3 -> "Wednesday"
      4 -> "Thursday"
      5 -> "Friday"
      6 -> "Saturday"
      7 -> "Sunday"
    end
  end

  @doc "Validates an announcement message template (`{{title}}`, `{{date}}`, `{{weekday}}` only)."
  @spec validate_message(String.t()) :: :ok | {:error, [String.t()]}
  def validate_message(source) when is_binary(source) do
    validate_tokens(source, @message_tokens)
  end

  @doc "Validates an announcement title template (`{{date}}`, `{{weekday}}` only)."
  @spec validate_title(String.t()) :: :ok | {:error, [String.t()]}
  def validate_title(source) when is_binary(source) do
    validate_tokens(source, @title_tokens)
  end

  @doc "Validates a Holiday Announcement template (`{{holidayName}}`, `{{date}}` only)."
  @spec validate_holiday_message(String.t()) :: :ok | {:error, [String.t()]}
  def validate_holiday_message(source) when is_binary(source) do
    validate_tokens(source, @holiday_tokens)
  end

  @doc """
  Renders a title template for `date`. Returns the thread name verbatim;
  rejects templates whose rendered title exceeds 100 characters.
  """
  @spec render_title(String.t(), Date.t()) :: {:ok, String.t()} | {:error, [String.t()]}
  def render_title(source, %Date{} = date) do
    with :ok <- validate_title(source) do
      rendered =
        substitute(source, %{"date" => format_date(date), "weekday" => format_weekday(date)})

      if String.length(rendered) > @title_max do
        {:error, ["title must be at most #{@title_max} characters after rendering"]}
      else
        {:ok, rendered}
      end
    end
  end

  @doc """
  Renders a message template with the resolved `title` and `date`.
  Prepends the `@everyone` line only when `mention_everyone?` is true, and
  rejects messages longer than 2,000 characters including that line.
  """
  @spec render_message(
          String.t(),
          %{required(:date) => Date.t(), optional(:title) => String.t()},
          boolean()
        ) ::
          {:ok, String.t()} | {:error, [String.t()]}
  def render_message(source, %{date: %Date{} = date} = assigns, mention_everyone?)
      when is_binary(source) and is_boolean(mention_everyone?) do
    with :ok <- validate_message(source) do
      title = Map.get(assigns, :title, "")

      rendered =
        substitute(source, %{
          "title" => title,
          "date" => format_date(date),
          "weekday" => format_weekday(date)
        })

      with_mention = if mention_everyone?, do: "@everyone\n" <> rendered, else: rendered

      if String.length(with_mention) > @message_max do
        {:error, ["message must be at most 2,000 characters after rendering"]}
      else
        {:ok, with_mention}
      end
    end
  end

  @doc """
  Renders the fixed Holiday Announcement copy. The `@everyone` line is
  always prepended: holiday posts always ping (ALE-317).
  """
  @spec render_holiday_message(String.t(), %{
          required(:date) => Date.t(),
          required(:holiday_name) => String.t()
        }) ::
          {:ok, String.t()} | {:error, [String.t()]}
  def render_holiday_message(source, %{date: %Date{} = date, holiday_name: holiday_name})
      when is_binary(source) and is_binary(holiday_name) do
    with :ok <- validate_holiday_message(source) do
      rendered =
        substitute(source, %{
          "holidayName" => holiday_name,
          "date" => format_date(date)
        })

      with_mention = "@everyone\n" <> rendered

      if String.length(with_mention) > @message_max do
        {:error, ["message must be at most 2,000 characters after rendering"]}
      else
        {:ok, with_mention}
      end
    end
  end

  defp validate_tokens(source, allowed) do
    names =
      Regex.scan(@token_re, source, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    stripped = Regex.replace(@token_re, source, "")

    errors =
      []
      |> check_malformed(stripped)
      |> check_unknown(names, allowed)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp check_malformed(errors, stripped) do
    if String.contains?(stripped, ["{{", "}}"]) do
      ["malformed token: every {{ must open a {{name}} token" | errors]
    else
      errors
    end
  end

  defp check_unknown(errors, names, allowed) do
    Enum.reduce(names, errors, fn name, acc ->
      if name in allowed do
        acc
      else
        ["unknown token {{#{name}}}" | acc]
      end
    end)
  end

  defp substitute(source, values) do
    Regex.replace(@token_re, source, fn _, name -> Map.fetch!(values, name) end)
  end

  @months %{
    1 => "January",
    2 => "February",
    3 => "March",
    4 => "April",
    5 => "May",
    6 => "June",
    7 => "July",
    8 => "August",
    9 => "September",
    10 => "October",
    11 => "November",
    12 => "December"
  }

  defp month_name(month), do: Map.fetch!(@months, month)
end
