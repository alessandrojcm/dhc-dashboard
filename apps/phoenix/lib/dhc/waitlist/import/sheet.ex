defmodule Dhc.Waitlist.Import.Sheet do
  @moduledoc """
  Reads the club's Waitlist spreadsheet export (spec story 123): a Google
  Forms sheet saved as CSV or TSV.

  The header row names the columns (trailing spaces allowed, e.g. `"Paid "`):
  Timestamp, Email address, Name, Date of birth, Mobile Number, the medical
  conditions question, Pronouns, the "signing up on behalf of your child"
  Guardian question, and Paid. The delimiter is a tab when the header row
  contains one, otherwise a comma.

  `parse/1` turns every data row into either registration-shaped attrs (for
  `Dhc.Waitlist.add_person/2`) or a refusal with a reason. It never guesses:

    * dates are day-first `dd/mm/yyyy` (Timestamp `dd/mm/yyyy HH:mm[:ss]`,
      Europe/Dublin local time) or ISO `yyyy-mm-dd`. If any Timestamp or date
      of birth is only valid month-first, the whole sheet is refused, because
      the sheet's locale is then not what this importer assumes;
    * the full name splits into first token and the rest; a single name is
      refused;
    * the Guardian free text must yield exactly one email, one phone number
      and a first and last name, or the row is refused;
    * Paid marks a person who already paid and holds a Carried Fee. The
      column is not well kept, so any non-blank text means a Carried Fee and
      blank means none; it is kept raw (`paid: %{raw, carried_fee?}`) for
      staff to match to the Stripe payment, never parsed further, never a
      standing and never a reason to refuse a row.
  """

  alias Dhc.ClubCalendar

  @type paid :: %{raw: String.t(), carried_fee?: boolean()}
  @type entry ::
          %{
            row: pos_integer(),
            email: String.t() | nil,
            attrs: map(),
            paid: paid(),
            notes: [String.t()]
          }
          | %{row: pos_integer(), email: String.t() | nil, error: String.t(), notes: [String.t()]}

  # {key, normalised header, match}: `:exact` headers are short and could
  # otherwise prefix-match another question.
  @columns [
    {:timestamp, "timestamp", :exact},
    {:email, "email address", :exact},
    {:name, "name", :exact},
    {:date_of_birth, "date of birth", :exact},
    {:phone, "mobile number", :exact},
    {:medical, "do you have any underlying medical conditions", :prefix},
    {:pronouns, "pronouns", :prefix},
    {:guardian, "are you signing up on behalf of your child", :prefix},
    {:paid, "paid", :exact}
  ]

  @email_pattern ~r/[^\s,;:<>()\[\]"']+@[^\s,;:<>()\[\]"']+\.[^\s,;:<>()\[\]"']+/u
  @phone_pattern ~r/\+?\d[\d \-().]{5,}\d/u
  @label_pattern ~r/\b(full name|name|email address|e-?mail|phone number|mobile number|phone|mobile|number|tel|contact|parent|guardian)\b\s*:?/iu

  @doc """
  Parses the export. Returns `{:ok, entries}` (one per data row, numbered by
  record with the header as row 1) or `{:error, reason}` when the sheet as a
  whole cannot be imported.
  """
  @spec parse(String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse(contents) when is_binary(contents) do
    contents = String.trim_leading(contents, "\uFEFF")
    delimiter = delimiter(contents)

    with {:ok, [header | records]} <- records(contents, delimiter),
         {:ok, index} <- column_index(header),
         numbered = Enum.with_index(records, 2),
         :ok <- ensure_day_first(numbered, index) do
      {:ok, numbered |> Enum.map(&entry(&1, index)) |> refuse_repeated_emails()}
    else
      {:ok, []} -> {:error, "the file is empty"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Delimited text ─────────────────────────────────────────────────

  defp delimiter(contents) do
    [first_line | _] = String.split(contents, ["\r\n", "\n", "\r"], parts: 2)
    if String.contains?(first_line, "\t"), do: ?\t, else: ?,
  end

  @doc false
  # RFC 4180 records: quoted fields may hold the delimiter, newlines and
  # doubled quotes. Rows whose every cell is blank are dropped.
  @spec records(String.t(), char()) :: {:ok, [[String.t()]]} | {:error, String.t()}
  def records(contents, delimiter) do
    case scan(contents, delimiter, :start, [], [], []) do
      {:ok, rows} ->
        {:ok, Enum.reject(rows, fn row -> Enum.all?(row, &(String.trim(&1) == "")) end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scan(<<>>, _d, :quoted, _field, _row, _rows),
    do: {:error, "the file has an unterminated quoted cell"}

  defp scan(<<>>, _d, state, field, row, rows) do
    rows =
      if state == :start and field == [] and row == [],
        do: rows,
        else: [finish(field, row) | rows]

    {:ok, Enum.reverse(rows)}
  end

  defp scan(<<?", ?", rest::binary>>, d, :quoted, field, row, rows),
    do: scan(rest, d, :quoted, [?" | field], row, rows)

  defp scan(<<?", rest::binary>>, d, :quoted, field, row, rows),
    do: scan(rest, d, :unquoted, field, row, rows)

  defp scan(<<c, rest::binary>>, d, :quoted, field, row, rows),
    do: scan(rest, d, :quoted, [c | field], row, rows)

  defp scan(<<?", rest::binary>>, d, :start, [], row, rows),
    do: scan(rest, d, :quoted, [], row, rows)

  defp scan(<<c, rest::binary>>, d, _state, field, row, rows) when c == d,
    do: scan(rest, d, :start, [], [field_string(field) | row], rows)

  defp scan(<<?\r, ?\n, rest::binary>>, d, _state, field, row, rows),
    do: scan(rest, d, :start, [], [], [finish(field, row) | rows])

  defp scan(<<c, rest::binary>>, d, _state, field, row, rows) when c in [?\n, ?\r],
    do: scan(rest, d, :start, [], [], [finish(field, row) | rows])

  defp scan(<<c, rest::binary>>, d, _state, field, row, rows),
    do: scan(rest, d, :unquoted, [c | field], row, rows)

  defp finish(field, row), do: Enum.reverse([field_string(field) | row])
  defp field_string(field), do: field |> Enum.reverse() |> IO.iodata_to_binary()

  # ── Columns ─────────────────────────────────────────────────────────

  defp column_index(header) do
    normalized = Enum.map(header, &normalize_header/1)

    @columns
    |> Enum.reduce_while({:ok, %{}}, fn {key, name, match}, {:ok, index} ->
      case Enum.find_index(normalized, &header_matches?(&1, name, match)) do
        nil -> {:halt, {:error, "the header row has no #{inspect(name)} column"}}
        position -> {:cont, {:ok, Map.put(index, key, position)}}
      end
    end)
  end

  defp normalize_header(header),
    do: header |> String.trim() |> String.downcase() |> String.replace(~r/\s+/u, " ")

  defp header_matches?(header, name, :exact), do: header == name
  defp header_matches?(header, name, :prefix), do: String.starts_with?(header, name)

  defp cell(record, index, key),
    do: record |> Enum.at(Map.fetch!(index, key), "") |> String.trim()

  # ── Dates ───────────────────────────────────────────────────────────

  defp ensure_day_first(numbered, index) do
    month_first =
      for {record, row} <- numbered,
          {key, label} <- [timestamp: "Timestamp", date_of_birth: "Date of birth"],
          value = cell(record, index, key),
          match?({:error, :month_first}, date_part(value)),
          do: "row #{row} #{label} #{inspect(value)}"

    case month_first do
      [] ->
        :ok

      cells ->
        {:error,
         "dates are only valid month-first, so the sheet's locale is not day-first; " <>
           "nothing was imported. Re-export with dd/mm/yyyy or ISO dates. " <>
           Enum.join(cells, "; ")}
    end
  end

  @doc false
  @spec parse_date(String.t()) :: {:ok, Date.t()} | {:error, :invalid | :month_first}
  def parse_date(value) do
    case date_part(value) do
      {:ok, date, ""} -> {:ok, date}
      {:ok, _date, _rest} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # A Timestamp is Europe/Dublin wall-clock time; stored as UTC.
  @spec parse_timestamp(String.t()) :: {:ok, DateTime.t()} | {:error, :invalid | :month_first}
  def parse_timestamp(value) do
    with {:ok, date, rest} <- date_part(value),
         {:ok, time} <- time_part(rest) do
      {:ok, ClubCalendar.to_utc(date, time)}
    end
  end

  defp date_part(value) do
    cond do
      match = Regex.run(~r/^(\d{4})-(\d{1,2})-(\d{1,2})(.*)$/u, value) ->
        [_, y, m, d, rest] = match
        build_date(int(y), int(m), int(d), rest)

      match = Regex.run(~r/^(\d{1,2})\/(\d{1,2})\/(\d{4})(.*)$/u, value) ->
        [_, d, m, y, rest] = match
        day_first(int(y), int(m), int(d), rest)

      true ->
        {:error, :invalid}
    end
  end

  defp day_first(year, month, day, rest) do
    case Date.new(year, month, day) do
      {:ok, date} ->
        {:ok, date, rest}

      {:error, _} ->
        if match?({:ok, _}, Date.new(year, day, month)),
          do: {:error, :month_first},
          else: {:error, :invalid}
    end
  end

  defp build_date(year, month, day, rest) do
    case Date.new(year, month, day) do
      {:ok, date} -> {:ok, date, rest}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp time_part(rest) do
    case Regex.run(~r/^[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$/u, String.trim_trailing(rest)) do
      [_, h, m] -> Time.new(int(h), int(m), 0) |> time_result()
      [_, h, m, s] -> Time.new(int(h), int(m), int(s)) |> time_result()
      nil -> {:error, :invalid}
    end
  end

  defp time_result({:ok, time}), do: {:ok, time}
  defp time_result({:error, _}), do: {:error, :invalid}

  defp int(digits), do: String.to_integer(digits)

  # ── Rows ────────────────────────────────────────────────────────────

  defp entry({record, row}, index) do
    email = cell(record, index, :email)
    notes = []

    paid = paid(cell(record, index, :paid))

    with {:ok, registered_at} <- timestamp(cell(record, index, :timestamp)),
         {:ok, date_of_birth} <- date_of_birth(cell(record, index, :date_of_birth)),
         {:ok, first_name, last_name} <- split_name(cell(record, index, :name)),
         {:ok, guardian} <- guardian(cell(record, index, :guardian)) do
      attrs =
        %{
          "firstName" => first_name,
          "lastName" => last_name,
          "email" => email,
          "phoneNumber" => cell(record, index, :phone),
          "dateOfBirth" => Date.to_iso8601(date_of_birth),
          "medicalConditions" => cell(record, index, :medical),
          "pronouns" => cell(record, index, :pronouns),
          "socialMediaConsent" => "no",
          "registeredAt" => registered_at
        }
        |> Map.merge(guardian)

      %{row: row, email: blank_to_nil(email), attrs: attrs, paid: paid, notes: notes}
    else
      {:error, reason} -> %{row: row, email: blank_to_nil(email), error: reason, notes: notes}
    end
  end

  defp timestamp(value) do
    case parse_timestamp(value) do
      {:ok, at} -> {:ok, at}
      {:error, _} -> {:error, "Timestamp #{inspect(value)} is not dd/mm/yyyy HH:mm:ss or ISO"}
    end
  end

  defp date_of_birth(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "Date of birth #{inspect(value)} is not dd/mm/yyyy or yyyy-mm-dd"}
    end
  end

  @doc false
  @spec split_name(String.t()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def split_name(name) do
    case String.split(String.trim(name), ~r/\s+/u, parts: 2) do
      [first, last] -> {:ok, first, String.trim(last)}
      _ -> {:error, "Name #{inspect(name)} needs a first and a last name"}
    end
  end

  @doc false
  @spec guardian(String.t()) :: {:ok, map()} | {:error, String.t()}
  def guardian(""), do: {:ok, %{}}

  def guardian(text) do
    emails = Regex.scan(@email_pattern, text) |> List.flatten()
    without_email = Regex.replace(@email_pattern, text, " ")
    phones = Regex.scan(@phone_pattern, without_email) |> List.flatten() |> Enum.filter(&phone?/1)

    name =
      @phone_pattern
      |> Regex.replace(without_email, " ")
      |> then(&Regex.replace(@label_pattern, &1, " "))
      |> String.replace(~r/[,;|\/\n\r\t:\-"]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    with [_email] <- emails,
         [phone] <- phones,
         {:ok, first, last} <- split_name(name) do
      {:ok,
       %{
         "guardianFirstName" => first,
         "guardianLastName" => last,
         "guardianPhoneNumber" => String.trim(phone)
       }}
    else
      _ ->
        {:error,
         "Guardian details #{inspect(text)} could not be read as a full name, one email " <>
           "and one phone number"}
    end
  end

  defp phone?(candidate), do: candidate |> String.replace(~r/\D/u, "") |> String.length() >= 7

  @doc """
  Reads a Paid cell: any non-blank text means the person paid and holds a
  Carried Fee, blank means not. The trimmed text is kept as `raw`.
  """
  @spec paid(String.t()) :: paid()
  def paid(cell) do
    raw = String.trim(cell)
    %{raw: raw, carried_fee?: raw != ""}
  end

  # A repeated email is refused at its later rows, naming the first one,
  # so a dry run reports it too.
  defp refuse_repeated_emails(entries) do
    {entries, _seen} =
      Enum.map_reduce(entries, %{}, fn entry, seen ->
        key = entry.email && String.downcase(entry.email)

        case key && Map.fetch(seen, key) do
          {:ok, first_row} ->
            {entry |> Map.delete(:attrs) |> Map.put(:error, "duplicate of row #{first_row}"),
             seen}

          _ ->
            {entry, if(key, do: Map.put(seen, key, entry.row), else: seen)}
        end
      end)

    entries
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
