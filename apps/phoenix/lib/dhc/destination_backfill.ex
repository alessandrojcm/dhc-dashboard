defmodule Dhc.DestinationBackfill do
  @moduledoc """
  The reviewed upcoming destination backfill (ALE-443): an operator previews a
  one-off, human-reviewed mapping from existing short venue labels to manual
  destinations, then explicitly applies it to exactly the targets they
  approved.

  This module is only the operator workflow: it reads each source's closed
  facts, matches labels against the reviewed mapping and reports every
  Workshop individually. It never writes a source row itself. Each source kind
  keeps its own storage, lock and authorization protocol behind an owner
  operation, so neither domain reads or writes the other's storage (ADR 0029).

  ## Owners

  `@owners` maps a source kind to the context that owns it. An owner exposes:

    * `destination_backfill_sources(now)` — the closed facts
      (`source_id`, `title`, `label`, `status`, `archived`, `starts_at`,
      `ends_at`, Dublin civil `date`/`start_time`/`end_time`, and
      `destination` with the `Dhc.Destinations.fields/0` keys) of every source
      that has not ended at `now`;
    * `check_destination_enrichment(facts, proposed, now)` — the advisory
      `:change | :unchanged | {:refused, reason}` reading;
    * `enrich_destination({:staff, principal_id}, source_id,
      %{expected: expected, destination: proposed}, opts)` — the authorized
      apply, which re-reads under the source's lock and returns
      `{:ok, :changed | :unchanged}` or `{:error, reason}`.

  Regular Workshops are `Dhc.Workshops`; Beginners' Workshops (ALE-444) are
  `Dhc.BeginnersWorkshops`, whose apply is the `enrich_destination` command
  of its own boundary (`execute/3`, `Commands.Schedule`), never a reschedule
  and never a cross-domain writer. Rows and targets are keyed by
  `{source_kind, source_id}`, so two sources sharing an id or a label stay
  distinct, and each target is applied in its owner's own transaction: a
  mixed run reports per target and is never atomic across domains.

  A Beginners' Workshop with no known end time reports `ends_at` and
  `end_time` as `nil`; its target's `expected.end_time` is then `null`.

  ## The mapping

      {
        "mappings": [
          {"venue": "Club hall",
           "destination": {"destination_text":
                             "National Basketball Arena, Tymon Park, Dublin 6w"}}
        ],
        "ambiguous": ["Main hall"]
      }

  Each entry is a reviewed manual destination for the same physical Venue as
  its label. Labels match after trimming, collapsing whitespace and ignoring
  case. A label listed as `ambiguous`, or mapped to two different
  destinations, never matches. Only the manual `destination_text` is accepted:
  there is no provider identity, no search and no first-result choice, and the
  mapping is not a reusable venue registry.

  ## Preview and apply

  `preview/2` is read-only: no Google call, no database or job write. It lists
  every not-yet-ended source with its label, schedule, status, current and
  proposed destination, outcome (`:change`, `:unchanged`, `:refused` with a
  reason) and expected Calendar effect, plus `proposed_targets` — the
  reviewed-facts shape `apply_plan/3` accepts under `approved_targets`. Copying a
  target into `approved_targets` is the deliberate approval.

  `apply_plan/3` takes the same mapping and the approved targets. The proposed
  destination always comes from the mapping for the target's expected label,
  never from the target itself; every target is applied by its owner, under
  its lock, against the facts the reviewer saw. Each target reports
  `:changed`, `:unchanged` or `:refused` with a reason. Sources that would now
  change but were not approved are reported as `discovered` and left alone.
  """

  alias Dhc.BeginnersWorkshops
  alias Dhc.Destinations
  alias Dhc.Destinations.Enrichment
  alias Dhc.WorkshopCalendar
  alias Dhc.Workshops

  @owners [workshop: Workshops, beginners_workshop: BeginnersWorkshops]

  # A mapping proposes manual text only; a reviewed destination also names the
  # selected place (`nil` for a manual one) so a Google selection is never
  # overwritten (`Dhc.Destinations.Enrichment.fields/0`).
  @mapping_fields [:destination_text]
  @destination_types Map.new(@mapping_fields, &{&1, :string})
  @destination_keys Enum.map(Enrichment.fields(), &Atom.to_string/1)
  @entry_keys ~w(venue destination note)
  @target_keys ~w(source_kind source_id expected)
  @expected_keys ~w(label status date start_time end_time destination)

  @type source_kind :: :workshop | :beginners_workshop
  @type mapping :: %{
          entries: [%{venue: String.t(), destination: map()}],
          ambiguous: [String.t()],
          index: %{String.t() => {:ok, map()} | :ambiguous}
        }

  @doc "The source kinds this workflow covers."
  @spec source_kinds() :: [source_kind()]
  def source_kinds, do: Keyword.keys(@owners)

  # ── Mapping ─────────────────────────────────────────────────────

  @doc """
  Parses a reviewed mapping document (JSON-decoded, string keys).

  The whole mapping is refused when any entry is malformed, so a typo can
  never silently drop or widen a reviewed venue.
  """
  @spec parse_mapping(term()) :: {:ok, mapping()} | {:error, [map()]}
  def parse_mapping(%{"mappings" => entries} = document) when is_list(entries) do
    ambiguous = Map.get(document, "ambiguous", [])

    parsed = entries |> Enum.with_index() |> Enum.map(fn {e, i} -> parse_entry(e, i) end)

    errors =
      Enum.flat_map(parsed, fn
        {:error, issue} -> [issue]
        {:ok, _} -> []
      end) ++
        unknown_keys(document, ~w(mappings ambiguous), "mapping") ++ ambiguous_errors(ambiguous)

    case errors do
      [] ->
        entries = for {:ok, entry} <- parsed, do: entry
        {:ok, %{entries: entries, ambiguous: ambiguous, index: index(entries, ambiguous)}}

      errors ->
        {:error, errors}
    end
  end

  def parse_mapping(_document),
    do: {:error, [%{at: "mapping", issue: "must be an object with a mappings list"}]}

  defp parse_entry(%{"venue" => venue, "destination" => destination} = entry, index)
       when is_binary(venue) and is_map(destination) do
    at = "mappings[#{index}]"

    with [] <- unknown_keys(entry, @entry_keys, at),
         [] <- unknown_keys(destination, @destination_keys, "#{at}.destination"),
         :ok <- manual_only(destination, "#{at}.destination"),
         {:ok, venue} <- parse_venue(venue, at),
         {:ok, destination} <- parse_destination(destination, "#{at}.destination") do
      {:ok, %{venue: venue, destination: destination}}
    else
      [issue | _] -> {:error, issue}
      {:error, issue} -> {:error, issue}
    end
  end

  defp parse_entry(_entry, index),
    do:
      {:error,
       %{at: "mappings[#{index}]", issue: "needs a venue string and a destination object"}}

  # A mapping proposes manual text: it never selects a Google place (the
  # echoed `destination_place_id: null` of a preview's mapping is allowed).
  defp manual_only(%{"destination_place_id" => place_id}, at) when not is_nil(place_id),
    do: {:error, %{at: at, issue: "a reviewed mapping names manual destinations only"}}

  defp manual_only(_destination, _at), do: :ok

  defp parse_venue(venue, at) do
    case Destinations.normalize_optional(venue) do
      nil -> {:error, %{at: "#{at}.venue", issue: "can't be blank"}}
      venue -> {:ok, venue}
    end
  end

  # A reviewed destination is validated by the same rule as the editors
  # (`Dhc.Destinations.validate_changeset/1`) and must say something.
  defp parse_destination(destination, at) do
    changeset =
      {Map.new(@mapping_fields, &{&1, nil}), @destination_types}
      |> Ecto.Changeset.cast(
        Map.take(destination, Enum.map(@mapping_fields, &Atom.to_string/1)),
        @mapping_fields,
        empty_values: []
      )
      |> Destinations.validate_changeset()

    cond do
      not changeset.valid? ->
        {:error, %{at: at, issue: changeset_issue(changeset)}}

      changeset |> Ecto.Changeset.apply_changes() |> Map.values() |> Enum.all?(&is_nil/1) ->
        {:error, %{at: at, issue: "names no destination detail"}}

      true ->
        {:ok, changeset |> Ecto.Changeset.apply_changes() |> Map.put(:destination_place_id, nil)}
    end
  end

  defp changeset_issue(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  defp unknown_keys(map, allowed, at) do
    for key <- Map.keys(map), key not in allowed, do: %{at: at, issue: "unknown key #{key}"}
  end

  defp ambiguous_errors(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: [],
      else: [%{at: "ambiguous", issue: "must list venue strings"}]
  end

  defp ambiguous_errors(_other), do: [%{at: "ambiguous", issue: "must list venue strings"}]

  defp index(entries, ambiguous) do
    mapped =
      entries
      |> Enum.group_by(&venue_key(&1.venue), & &1.destination)
      |> Map.new(fn {key, destinations} ->
        case Enum.uniq(destinations) do
          [destination] -> {key, {:ok, destination}}
          _different -> {key, :ambiguous}
        end
      end)

    Enum.reduce(ambiguous, mapped, &Map.put(&2, venue_key(&1), :ambiguous))
  end

  defp venue_key(venue) do
    venue |> String.trim() |> String.replace(~r/\s+/u, " ") |> String.downcase()
  end

  defp lookup(mapping, label) do
    case Map.get(mapping.index, venue_key(label || "")) do
      {:ok, destination} -> {:mapped, destination}
      :ambiguous -> :ambiguous
      nil -> :unmatched
    end
  end

  # ── Preview ─────────────────────────────────────────────────────

  @doc """
  Read-only preview of every not-yet-ended source under `mapping`.

  Options: `:clock` (`(-> DateTime.t())`, default `DateTime.utc_now/0`).
  """
  @spec preview(mapping(), keyword()) :: map()
  def preview(mapping, opts \\ []) do
    now = clock(opts).()
    active = WorkshopCalendar.outbound?()
    rows = rows(mapping, now, active)

    %{
      generated_at: now,
      calendar_sending_active: active,
      mapping: echo(mapping),
      summary: summary(rows, :outcome),
      workshops: rows,
      proposed_targets: for(row <- rows, row.outcome == :change, do: target(row))
    }
  end

  defp rows(mapping, now, active) do
    for {kind, owner} <- @owners,
        facts <- owner.destination_backfill_sources(now),
        do: row(kind, owner, facts, mapping, now, active)
  end

  defp row(kind, owner, facts, mapping, now, active) do
    {match, proposed} =
      case lookup(mapping, facts.label) do
        {:mapped, destination} -> {:mapped, destination}
        other -> {other, nil}
      end

    {outcome, reason} =
      case proposed && owner.check_destination_enrichment(facts, proposed, now) do
        nil -> {:refused, unmatched_reason(match)}
        {:refused, reason} -> {:refused, reason}
        outcome -> {outcome, nil}
      end

    %{
      source_kind: kind,
      source_id: facts.source_id,
      title: facts.title,
      label: facts.label,
      status: facts.status,
      archived: facts.archived,
      starts_at: facts.starts_at,
      ends_at: facts.ends_at,
      date: facts.date,
      start_time: facts.start_time,
      end_time: facts.end_time,
      match: match,
      current_destination: facts.destination,
      proposed_destination: proposed,
      outcome: outcome,
      reason: reason,
      calendar: calendar_effect(facts, proposed, outcome, active)
    }
  end

  defp unmatched_reason(:ambiguous), do: :ambiguous_venue
  defp unmatched_reason(:unmatched), do: :unreviewed_venue

  defp calendar_effect(facts, proposed, outcome, active) do
    before = location(facts.destination, facts.label)
    later = if outcome == :change, do: location(proposed, facts.label), else: before

    effect =
      cond do
        before == later -> :none
        active -> :update_existing_events
        true -> :retained_until_activation
      end

    %{location_before: before, location_after: later, effect: effect}
  end

  defp location(destination, label),
    do: Destinations.calendar_location(destination.destination_text, label)

  defp target(row) do
    %{
      source_kind: row.source_kind,
      source_id: row.source_id,
      expected: %{
        label: row.label,
        status: row.status,
        date: row.date,
        start_time: row.start_time,
        end_time: row.end_time,
        destination: row.current_destination
      }
    }
  end

  defp echo(mapping) do
    %{
      mappings: Enum.map(mapping.entries, &%{venue: &1.venue, destination: &1.destination}),
      ambiguous: mapping.ambiguous
    }
  end

  defp summary(rows, key), do: rows |> Enum.frequencies_by(&Map.fetch!(&1, key))

  # ── Apply ───────────────────────────────────────────────────────

  @doc """
  Applies the approved targets of a reviewed plan as `actor`
  (`{:staff, principal_id}`).

  `plan` is a JSON-decoded document with `mapping` (the `parse_mapping/1`
  shape) and `approved_targets` (the `proposed_targets` shape from
  `preview/2`). Options: `:clock`, passed to every owner, which reads it under
  its lock.
  """
  @spec apply_plan(map(), {:staff, binary()}, keyword()) ::
          {:ok, map()} | {:error, [map()]}
  def apply_plan(plan, actor, opts \\ [])

  def apply_plan(%{"mapping" => mapping, "approved_targets" => targets} = plan, actor, opts)
      when is_list(targets) do
    with [] <- unknown_keys(plan, ~w(mapping approved_targets), "plan"),
         {:ok, mapping} <- parse_mapping(mapping) do
      {results, _seen} =
        targets
        |> Enum.with_index()
        |> Enum.map_reduce(MapSet.new(), fn {target, index}, seen ->
          apply_target(target, index, seen, mapping, actor, opts)
        end)

      approved = MapSet.new(results, &{&1.source_kind, &1.source_id})
      now = clock(opts).()

      discovered =
        for row <- rows(mapping, now, WorkshopCalendar.outbound?()),
            row.outcome == :change,
            not MapSet.member?(approved, {row.source_kind, row.source_id}),
            do: Map.take(row, [:source_kind, :source_id, :label, :date, :proposed_destination])

      {:ok, %{summary: summary(results, :outcome), results: results, discovered: discovered}}
    else
      {:error, issues} -> {:error, issues}
      [_ | _] = issues -> {:error, issues}
    end
  end

  def apply_plan(_plan, _actor, _opts),
    do: {:error, [%{at: "plan", issue: "must be an object with mapping and approved_targets"}]}

  defp apply_target(target, index, seen, mapping, actor, opts) do
    case parse_target(target, index) do
      {:error, issue} ->
        {Map.merge(raw_identity(target), %{
           outcome: :refused,
           reason: :invalid_target,
           issue: issue
         }), seen}

      {:ok, {kind, id, expected}} ->
        result =
          if MapSet.member?(seen, {kind, id}),
            do: {:error, :duplicate_target},
            else: enrich(kind, id, expected, mapping, actor, opts)

        {outcome(kind, id, result), MapSet.put(seen, {kind, id})}
    end
  end

  defp enrich(kind, id, expected, mapping, actor, opts) do
    case lookup(mapping, expected.label) do
      {:mapped, destination} ->
        Keyword.fetch!(@owners, kind).enrich_destination(
          actor,
          id,
          %{expected: expected, destination: destination},
          opts
        )

      :ambiguous ->
        {:error, :ambiguous_venue}

      :unmatched ->
        {:error, :unreviewed_venue}
    end
  end

  defp outcome(kind, id, {:ok, outcome}),
    do: %{source_kind: kind, source_id: id, outcome: outcome, reason: nil}

  defp outcome(kind, id, {:error, reason}),
    do: %{source_kind: kind, source_id: id, outcome: :refused, reason: reason}

  defp raw_identity(target) when is_map(target),
    do: %{source_kind: target["source_kind"], source_id: target["source_id"]}

  defp raw_identity(_target), do: %{source_kind: nil, source_id: nil}

  defp parse_target(%{"expected" => expected} = target, index) when is_map(expected) do
    at = "approved_targets[#{index}]"

    with [] <- unknown_keys(target, @target_keys, at),
         [] <- unknown_keys(expected, @expected_keys, "#{at}.expected"),
         {:ok, kind} <- parse_kind(target["source_kind"]),
         {:ok, id} <- Ecto.UUID.cast(target["source_id"]),
         {:ok, expected} <- parse_expected(expected) do
      {:ok, {kind, id, expected}}
    else
      [issue | _] -> {:error, issue.issue}
      {:error, issue} -> {:error, issue}
      :error -> {:error, "source_id must be a UUID"}
    end
  end

  defp parse_target(_target, _index), do: {:error, "needs source_kind, source_id and expected"}

  defp parse_kind(kind) when is_binary(kind) do
    case Enum.find(source_kinds(), &(Atom.to_string(&1) == kind)) do
      nil -> {:error, "unknown source_kind #{kind}"}
      kind -> {:ok, kind}
    end
  end

  defp parse_kind(_kind), do: {:error, "source_kind is required"}

  # The expected facts are taken literally: no trimming or case folding, so a
  # target can only describe the source exactly as it was reviewed.
  defp parse_expected(%{"destination" => destination} = expected) when is_map(destination) do
    with true <- is_binary(expected["label"]) and is_binary(expected["status"]),
         {:ok, date} <- parse_date(expected["date"]),
         {:ok, start_time} <- parse_time(expected["start_time"]),
         {:ok, end_time} <- parse_optional_time(expected["end_time"]),
         true <- Enum.sort(Map.keys(destination)) == Enum.sort(@destination_keys),
         true <- Enum.all?(Map.values(destination), &(is_nil(&1) or is_binary(&1))) do
      {:ok,
       %{
         label: expected["label"],
         status: expected["status"],
         date: date,
         start_time: start_time,
         end_time: end_time,
         destination: Map.new(Enrichment.fields(), &{&1, destination[Atom.to_string(&1)]})
       }}
    else
      _invalid -> {:error, "expected facts are incomplete or malformed"}
    end
  end

  defp parse_expected(_expected), do: {:error, "expected facts are incomplete or malformed"}

  defp parse_date(text) when is_binary(text), do: Date.from_iso8601(text)
  defp parse_date(_text), do: {:error, :invalid_format}

  defp parse_time(text) when is_binary(text), do: Time.from_iso8601(text)
  defp parse_time(_text), do: {:error, :invalid_format}

  # A legacy Beginners' Workshop may have no known end time yet.
  defp parse_optional_time(nil), do: {:ok, nil}
  defp parse_optional_time(text), do: parse_time(text)

  defp clock(opts), do: Keyword.get(opts, :clock, &DateTime.utc_now/0)
end
