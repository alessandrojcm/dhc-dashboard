defmodule Dhc.Waitlist.Import do
  @moduledoc """
  The one-time import of the club's Waitlist spreadsheet (spec story 123).

  This module is the column-agnostic half: it takes rows already mapped to
  the public registration shape (`firstName`, `lastName`, `email`,
  `phoneNumber`, `dateOfBirth`, `gender`, `medicalConditions`, optional
  `pronouns`, `socialMediaConsent` and guardian fields) plus an optional
  `registeredAt`, the person's original spreadsheet registration time, which
  becomes their priority.

  Every row goes through `Dhc.Waitlist.add_person/2`, so it is validated
  exactly like registration (first name included) and refused with the same
  reasons, in its own transaction. Rows are never dropped silently: the
  result lists every imported row and every refused row with its reason.
  A repeated email in the file is refused as `:email_on_waitlist`, so
  re-running the import is safe.
  """

  alias Dhc.Waitlist

  @type row_number :: pos_integer()
  @type result :: %{
          imported: [%{row: row_number(), id: Ecto.UUID.t(), email: String.t()}],
          refused: [%{row: row_number(), email: String.t() | nil, reason: String.t()}]
        }

  @doc """
  Imports `rows` in order. Row numbers start at `opts[:first_row]` (default
  1), so a caller can report spreadsheet line numbers.
  """
  @spec run([map()], keyword()) :: result()
  def run(rows, opts \\ []) when is_list(rows) do
    first_row = Keyword.get(opts, :first_row, 1)

    rows
    |> Enum.with_index(first_row)
    |> Enum.reduce(%{imported: [], refused: []}, fn {row, number}, acc ->
      case import_row(row, opts) do
        {:ok, id} ->
          %{acc | imported: [%{row: number, id: id, email: email(row)} | acc.imported]}

        {:error, reason} ->
          %{acc | refused: [%{row: number, email: email(row), reason: reason} | acc.refused]}
      end
    end)
    |> then(&%{imported: Enum.reverse(&1.imported), refused: Enum.reverse(&1.refused)})
  end

  defp import_row(row, opts) when is_map(row) do
    with {:ok, registered_at} <- registered_at(row, opts),
         {:ok, %{id: id}} <-
           Waitlist.add_person(Map.delete(row, "registeredAt"), now: registered_at) do
      {:ok, id}
    else
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp import_row(_row, _opts), do: {:error, "not a row"}

  defp registered_at(%{"registeredAt" => %DateTime{} = at}, _opts), do: {:ok, at}

  defp registered_at(%{"registeredAt" => %Date{} = date}, _opts),
    do: {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}

  defp registered_at(%{"registeredAt" => value}, _opts) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        {:ok, at}

      {:error, _reason} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          {:error, _reason} -> {:error, :invalid_registered_at}
        end
    end
  end

  defp registered_at(_row, opts), do: {:ok, Keyword.get(opts, :now, DateTime.utc_now())}

  defp describe(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)

  defp email(%{"email" => email}) when is_binary(email), do: email
  defp email(_row), do: nil
end
