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

  `:change`, `:unchanged` (`Dhc.Destinations.Enrichment.outcome/2`, shared
  with Beginners' Workshops) or `{:refused, reason}` — one of `t:refusal/0`.
  """

  alias Dhc.ClubCalendar
  alias Dhc.Destinations
  alias Dhc.Destinations.Enrichment
  alias Dhc.Workshops.Workshop

  @eligible_statuses ~w(planned published)

  @type destination :: Enrichment.destination()

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

  @type expected :: Enrichment.expected()

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
    with :ok <- eligible(facts, now), do: Enrichment.outcome(facts.destination, proposed)
  end

  @doc """
  `check/3` for an approved target, judged under the Workshop lock.

  Between eligibility and the proposal it requires the current facts to still
  be the ones the reviewer approved (`Dhc.Destinations.Enrichment.still_reviewed/3`):
  a stale label, schedule, status or destination is refused, never
  overwritten. A destination that already equals the proposal is
  `:unchanged`, so repeating an applied plan is a no-op.
  """
  @spec check_reviewed(facts() | nil, expected(), destination(), DateTime.t()) ::
          :change | :unchanged | {:refused, refusal()}
  def check_reviewed(facts, expected, proposed, %DateTime{} = now) do
    with :ok <- eligible(facts, now),
         :ok <- Enrichment.still_reviewed(facts, expected, proposed),
         do: Enrichment.outcome(facts.destination, proposed)
  end

  defp eligible(nil, _now), do: {:refused, :not_found}
  defp eligible(%{archived: true}, _now), do: {:refused, :archived}
  defp eligible(%{status: "cancelled"}, _now), do: {:refused, :cancelled}

  defp eligible(%{status: status}, _now) when status not in @eligible_statuses,
    do: {:refused, :not_eligible_status}

  defp eligible(facts, now) do
    if DateTime.compare(facts.starts_at, now) == :gt, do: :ok, else: {:refused, :started}
  end
end
