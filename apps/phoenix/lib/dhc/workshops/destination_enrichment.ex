defmodule Dhc.Workshops.DestinationEnrichment do
  @moduledoc """
  The one rule for a reviewed same-Venue destination enrichment of a regular
  Workshop (ALE-443).

  Enrichment adds manually reviewed destination details (`destination_name`,
  `destination_address`, `directions_url`) to an upcoming Workshop whose short
  venue label a human has matched to the same physical Venue. It is the narrow
  exception to the planned-only editor: it never changes the label, schedule,
  status or any place, payment or refund fact, and never moves a Workshop to
  another Venue.

  Facts are a closed map built only by `facts/1` from a `Workshop` row, so the
  advisory preview (`Dhc.Workshops.destination_backfill_sources/1`) and the
  authoritative apply under the Workshop lock
  (`Dhc.Workshops.enrich_destination/4`) judge exactly the same shape with the
  same `check/3`; they cannot disagree. Schedules are compared on the Club
  Calendar's Dublin civil date and times, the reading a reviewer approved.

  ## Outcomes

    * `:change` — every stored destination field is absent or already equal
      to the proposal, and at least one differs;
    * `:unchanged` — the stored destination already is the proposal;
    * `{:refused, reason}` — one of `t:refusal/0`.
  """

  alias Dhc.ClubCalendar
  alias Dhc.Destinations
  alias Dhc.Workshops.Workshop

  @eligible_statuses ~w(planned published)

  @type destination :: %{
          destination_name: String.t() | nil,
          destination_address: String.t() | nil,
          directions_url: String.t() | nil
        }

  @type facts :: %{
          source_id: binary(),
          title: String.t(),
          label: String.t(),
          status: String.t(),
          archived: boolean(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          date: Date.t(),
          start_time: Time.t(),
          end_time: Time.t(),
          destination: destination()
        }

  @typedoc """
  The reviewed current facts an approved target names: the short label, the
  status and Dublin civil schedule, and the destination the reviewer saw.
  """
  @type expected :: %{
          label: String.t(),
          status: String.t(),
          date: Date.t(),
          start_time: Time.t(),
          end_time: Time.t(),
          destination: destination()
        }

  @type refusal ::
          :not_found
          | :archived
          | :cancelled
          | :not_eligible_status
          | :started
          | :label_changed
          | :rescheduled
          | :status_changed
          | :destination_changed
          | :destination_conflict

  @doc "The closed facts of one Workshop row."
  @spec facts(Workshop.t()) :: facts()
  def facts(%Workshop{} = workshop) do
    %{
      source_id: workshop.id,
      title: workshop.title,
      label: workshop.location,
      status: workshop.status,
      archived: not is_nil(workshop.archived_at),
      starts_at: workshop.start_date,
      ends_at: workshop.end_date,
      date: ClubCalendar.on_date(workshop.start_date),
      start_time: ClubCalendar.time_on(workshop.start_date),
      end_time: ClubCalendar.time_on(workshop.end_date),
      destination: Map.new(Destinations.fields(), &{&1, Map.fetch!(workshop, &1)})
    }
  end

  @doc """
  Whether `proposed` may enrich the Workshop described by `facts` at `now`:
  the advisory reading the preview reports.

  `nil` facts mean the Workshop no longer exists. A started Workshop (its
  start instant at or before `now`) is never enriched, so an ended event's
  detail cutoff is never reached through this path.
  """
  @spec check(facts() | nil, destination(), DateTime.t()) ::
          :change | :unchanged | {:refused, refusal()}
  def check(facts, proposed, %DateTime{} = now) do
    with :ok <- eligible(facts, now), do: proposal(facts.destination, proposed)
  end

  @doc """
  `check/3` for an approved target, judged under the Workshop lock.

  Between eligibility and the proposal it requires the current facts to still
  be the ones the reviewer approved: a different label means the Workshop may
  have moved Venue, and a different schedule, status or destination means the
  review is stale. Neither is overwritten. A destination that already equals
  the proposal is `:unchanged`, so repeating an applied plan is a no-op.
  """
  @spec check_reviewed(facts() | nil, expected(), destination(), DateTime.t()) ::
          :change | :unchanged | {:refused, refusal()}
  def check_reviewed(facts, expected, proposed, %DateTime{} = now) do
    with :ok <- eligible(facts, now),
         :ok <- still_reviewed(facts, expected, proposed),
         do: proposal(facts.destination, proposed)
  end

  defp eligible(nil, _now), do: {:refused, :not_found}
  defp eligible(%{archived: true}, _now), do: {:refused, :archived}
  defp eligible(%{status: "cancelled"}, _now), do: {:refused, :cancelled}

  defp eligible(%{status: status}, _now) when status not in @eligible_statuses,
    do: {:refused, :not_eligible_status}

  defp eligible(facts, now) do
    if DateTime.compare(facts.starts_at, now) == :gt, do: :ok, else: {:refused, :started}
  end

  # A destination that already is the proposal is the reviewed end state, so
  # repeating an applied plan (or a duplicate driver) is unchanged, not stale.
  defp still_reviewed(facts, expected, proposed) do
    cond do
      facts.label != expected.label ->
        {:refused, :label_changed}

      {facts.date, facts.start_time, facts.end_time} !=
          {expected.date, expected.start_time, expected.end_time} ->
        {:refused, :rescheduled}

      facts.status != expected.status ->
        {:refused, :status_changed}

      facts.destination not in [expected.destination, proposed] ->
        {:refused, :destination_changed}

      true ->
        :ok
    end
  end

  defp proposal(current, proposed) do
    cond do
      current == proposed -> :unchanged
      enrichment?(current, proposed) -> :change
      true -> {:refused, :destination_conflict}
    end
  end

  # Enrichment only fills absent fields: a stored value that differs from the
  # proposal (including one the proposal would clear) is a different
  # destination, which the ordinary editor owns.
  defp enrichment?(current, proposed) do
    Enum.all?(Destinations.fields(), fn field ->
      value = Map.fetch!(current, field)
      is_nil(value) or value == Map.fetch!(proposed, field)
    end)
  end
end
