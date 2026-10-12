defmodule Dhc.Waitlist.Import do
  @moduledoc """
  The one-time import of the club's Waitlist spreadsheet (spec story 123).

  `import_sheet/2` reads a CSV/TSV export through `Dhc.Waitlist.Import.Sheet`
  and imports every readable row through `Dhc.Waitlist.add_person/2`, so a row
  is validated exactly like registration (first name included) and refused
  with the same reasons, each in its own transaction. Two exceptions, decided
  for the sheet: social media consent is `no` and gender is stored as none
  (`gender: :optional`), because the sheet has neither.

  Every imported person becomes `waiting` with the sheet's Timestamp as their
  priority. Rows are never dropped silently: the report lists every imported
  row with its Paid value, every refused row with its reason, and review
  notes (Guardian details given for an adult). Re-running is safe: an email
  already on the Waitlist is refused as `email_on_waitlist`.

  ## Paid and Carried Fees

  A Paid cell marks someone who already paid and holds a Carried Fee. Each
  row carries it as `paid: %{raw, carried_fee?}`: any non-blank text is a
  Carried Fee, and the raw text is reported for matching to Stripe. The
  `:carried_fee` option is the one extension point: it runs inside the
  row's own transaction, right after the person is inserted. Run the import
  through `Dhc.BeginnersWorkshops.import_waitlist/2` (as the mix task and
  `Dhc.Release.import_waitlist/2` do), which injects the step that creates
  the `held` Carried Fee (ALE-388); called directly, this module creates
  none (`create_carried_fee/2` is a no-op).

  `dry_run: true` validates every row against the database and returns the
  same report, but rolls each row back, so nothing is written.

  Running it in production is a human step: `mix dhc.waitlist.import` or
  `Dhc.Release.import_waitlist/2`.
  """

  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.Import.Sheet

  @minimum_age 16
  @adult_age 18

  @type report :: %{
          dry_run: boolean(),
          imported: [
            %{
              row: pos_integer(),
              email: String.t() | nil,
              id: Ecto.UUID.t() | nil,
              paid: Sheet.paid()
            }
          ],
          refused: [%{row: pos_integer(), email: String.t() | nil, reason: String.t()}],
          notes: [%{row: pos_integer(), email: String.t() | nil, note: String.t()}]
        }

  @doc """
  Imports a sheet export. `{:error, reason}` means the sheet as a whole was
  refused (missing columns, month-first dates) and nothing was written.
  """
  @spec import_sheet(String.t(), keyword()) :: {:ok, report()} | {:error, String.t()}
  def import_sheet(contents, opts \\ []) when is_binary(contents) do
    with {:ok, entries} <- Sheet.parse(contents) do
      {:ok, import_entries(entries, opts)}
    end
  end

  @doc """
  Imports rows already mapped to the registration shape plus an optional
  `registeredAt` (the priority; defaults to `opts[:now]` or now). Row numbers
  start at `opts[:first_row]` (default 1).
  """
  @spec run([map()], keyword()) :: report()
  def run(rows, opts \\ []) when is_list(rows) do
    rows
    |> Enum.with_index(Keyword.get(opts, :first_row, 1))
    |> Enum.map(fn {row, number} -> run_entry(row, number) end)
    |> import_entries(opts)
  end

  defp run_entry(row, number) do
    {raw, attrs} = Map.pop(row, "paid", "")
    %{row: number, email: email(row), attrs: attrs, paid: Sheet.paid(raw), notes: []}
  end

  @doc """
  The default Carried Fee step: a no-op. The real one is injected as the
  `:carried_fee` option (`fn waitlist_entry_id, paid -> :ok | {:error, term} end`)
  by `Dhc.BeginnersWorkshops.import_waitlist/2` (ALE-388), which the mix task
  and `Dhc.Release.import_waitlist/2` use: the Waitlist never calls up into
  Beginners' Workshops. The step runs inside the row's transaction, after
  the Waitlist entry is inserted, so a failure there rolls the row back and
  refuses it.
  """
  @spec create_carried_fee(Ecto.UUID.t(), Sheet.paid()) :: :ok | {:error, term()}
  def create_carried_fee(_waitlist_entry_id, %{carried_fee?: _carried_fee?}), do: :ok

  @doc "Formats a report as printable lines."
  @spec format_report(report()) :: [String.t()]
  def format_report(report) do
    mode = if report.dry_run, do: "DRY RUN (nothing written)", else: "IMPORTED"
    verb = if report.dry_run, do: "would import", else: "imported"

    [
      "Waitlist import: #{mode}. #{length(report.imported)} #{verb}, " <>
        "#{length(report.refused)} refused, #{length(report.notes)} to review."
    ] ++
      section("Imported", report.imported, &paid_text/1) ++
      section("Refused", report.refused, & &1.reason) ++
      section("Review", report.notes, & &1.note)
  end

  defp paid_text(%{paid: %{carried_fee?: true, raw: raw}}),
    do: "carried fee: yes (raw: #{inspect(raw)})"

  defp paid_text(_imported), do: ""

  defp section(_title, [], _detail), do: []

  defp section(title, items, detail) do
    ["", "#{title}:"] ++
      Enum.map(items, fn item ->
        line = "  row #{item.row} #{item.email || "(no email)"}"

        case detail.(item) do
          "" -> line
          text -> "#{line}: #{text}"
        end
      end)
  end

  defp import_entries(entries, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    today = Keyword.get_lazy(opts, :today, &ClubCalendar.today/0)

    report =
      Enum.reduce(entries, %{dry_run: dry_run?, imported: [], refused: [], notes: []}, fn entry,
                                                                                          acc ->
        acc = add_notes(acc, entry, today)

        case import_entry(entry, today, dry_run?, opts) do
          {:ok, id} ->
            imported = %{row: entry.row, email: entry.email, id: id, paid: entry.paid}
            %{acc | imported: [imported | acc.imported]}

          {:error, reason} ->
            %{
              acc
              | refused: [%{row: entry.row, email: entry.email, reason: reason} | acc.refused]
            }
        end
      end)

    %{
      report
      | imported: Enum.reverse(report.imported),
        refused: Enum.reverse(report.refused),
        notes: Enum.reverse(report.notes)
    }
  end

  defp add_notes(acc, %{notes: notes} = entry, today) do
    notes =
      if adult_with_guardian?(entry, today),
        do: notes ++ ["review: Guardian details given for an adult were not imported"],
        else: notes

    Enum.reduce(notes, acc, fn note, acc ->
      %{acc | notes: [%{row: entry.row, email: entry.email, note: note} | acc.notes]}
    end)
  end

  defp import_entry(%{error: reason}, _today, _dry_run?, _opts), do: {:error, reason}

  defp import_entry(%{attrs: attrs, paid: paid}, today, dry_run?, opts) when is_map(attrs) do
    carried_fee = Keyword.get(opts, :carried_fee, &create_carried_fee/2)

    with {:ok, registered_at} <- registered_at(attrs, opts),
         :ok <- precheck_age(attrs, today) do
      attrs
      |> Map.delete("registeredAt")
      |> add(registered_at, paid, carried_fee, dry_run?)
      |> case do
        {:ok, %{id: id}} -> {:ok, if(dry_run?, do: nil, else: id)}
        {:error, reason} -> {:error, describe(reason)}
      end
    else
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp import_entry(_entry, _today, _dry_run?, _opts), do: {:error, "not a row"}

  # The person and their Carried Fee commit together in the row's own
  # transaction. A dry run always rolls that transaction back, so it checks
  # the database exactly as the import would.
  defp add(attrs, registered_at, paid, carried_fee, dry_run?) do
    Repo.transaction(fn ->
      result =
        with {:ok, person} <- Waitlist.add_person(attrs, now: registered_at, gender: :optional),
             :ok <- carried_fee.(person.id, paid) do
          {:ok, person}
        end

      case result do
        {:ok, _person} when dry_run? -> Repo.rollback({:dry_run, result})
        {:ok, person} -> person
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:error, {:dry_run, result}} -> result
      other -> other
    end
  end

  # Clearer reasons than registration's `invalid_payload` for the two age
  # rules; `add_person/2` still enforces both.
  defp precheck_age(%{"dateOfBirth" => dob} = attrs, today) when is_binary(dob) do
    case Date.from_iso8601(dob) do
      {:ok, date} ->
        age = age(date, today)

        cond do
          age < @minimum_age ->
            {:error, "under #{@minimum_age} (born #{dob})"}

          age < @adult_age and blank?(attrs["guardianFirstName"]) ->
            {:error, "under #{@adult_age} with no Guardian details"}

          true ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp precheck_age(_attrs, _today), do: :ok

  defp adult_with_guardian?(%{attrs: %{"dateOfBirth" => dob, "guardianFirstName" => _}}, today) do
    case Date.from_iso8601(dob) do
      {:ok, date} -> age(date, today) >= @adult_age
      _ -> false
    end
  end

  defp adult_with_guardian?(_entry, _today), do: false

  defp age(date_of_birth, today) do
    years = today.year - date_of_birth.year

    if {today.month, today.day} < {date_of_birth.month, date_of_birth.day},
      do: years - 1,
      else: years
  end

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

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)

  defp blank?(value), do: value in [nil, ""]

  defp email(%{"email" => email}) when is_binary(email), do: email
  defp email(_row), do: nil
end
