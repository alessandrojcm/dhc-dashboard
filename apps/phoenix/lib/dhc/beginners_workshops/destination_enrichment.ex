defmodule Dhc.BeginnersWorkshops.DestinationEnrichment do
  @moduledoc """
  The one rule for a reviewed same-Venue destination enrichment of a
  Beginners' Workshop (ALE-444), the Beginners' Workshop owner of the
  operator workflow in `Dhc.DestinationBackfill`.

  Enrichment adds manually reviewed destination text (`destination_text`) to
  an upcoming scheduled workshop whose short `venue` label a human has
  matched to the same physical Venue.
  It is not a reschedule: the label, date, times, Payment Cutoff, offer
  rounds, `reschedule_count`, Staff and every place, payment, refund and
  attendance fact stay as they are, and no email or Staff Notification is
  queued.

  Facts are a closed map built only by `facts/1` from a `BeginnersWorkshop`
  row, the shape every backfill owner reports (`label` is the `venue`; the
  date and times are already Dublin civil values). The advisory preview
  (`Dhc.BeginnersWorkshops.destination_backfill_sources/1`) and the
  authoritative `enrich_destination` command under the Beginners' Workshop
  lock (`Commands.Schedule`) judge that shape with the same functions, so
  they cannot disagree. The stale-fact and proposal comparisons are the
  domain-neutral `Dhc.Destinations.Enrichment`; eligibility is this module's.

  ## Outcomes

  `:change`, `:unchanged` or `{:refused, reason}` — one of `t:refusal/0`.
  Only a `scheduled` workshop whose start is still after `now` is eligible:
  a cancelled one is `:cancelled`, a finalised one `:not_eligible_status` and
  a started one `:started`.
  """

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, CalendarProjection}
  alias Dhc.Destinations.Enrichment

  @type destination :: Enrichment.destination()
  @type expected :: Enrichment.expected()

  @type facts :: %{
          source_id: binary(),
          title: String.t(),
          label: String.t(),
          status: String.t(),
          archived: false,
          starts_at: DateTime.t(),
          ends_at: DateTime.t() | nil,
          date: Date.t(),
          start_time: Time.t(),
          end_time: Time.t() | nil,
          destination: destination()
        }

  @type refusal ::
          :not_found
          | :cancelled
          | :not_eligible_status
          | :started
          | Enrichment.stale()
          | :destination_conflict

  @doc """
  The closed facts of one Beginners' Workshop row. `ends_at` is `nil` while
  the workshop has no valid end time (Calendar's own reading); `end_time` is
  the stored civil value, `nil` when unknown.
  """
  @spec facts(BeginnersWorkshop.t()) :: facts()
  def facts(%BeginnersWorkshop{} = workshop) do
    projection = CalendarProjection.project(workshop)

    %{
      source_id: workshop.id,
      title: projection.title,
      label: workshop.venue,
      status: workshop.status,
      archived: false,
      starts_at: projection.start_date,
      ends_at: projection.end_date,
      date: workshop.date,
      start_time: workshop.start_time,
      end_time: workshop.end_time,
      destination: Map.new(Enrichment.fields(), &{&1, Map.fetch!(workshop, &1)})
    }
  end

  @doc """
  Whether `proposed` may enrich the workshop described by `facts` at `now`:
  the advisory reading the preview reports. `nil` facts mean the workshop no
  longer exists.
  """
  @spec check(facts() | nil, destination(), DateTime.t()) ::
          :change | :unchanged | {:refused, refusal()}
  def check(facts, proposed, %DateTime{} = now) do
    with :ok <- eligible(facts, now), do: Enrichment.outcome(facts.destination, proposed)
  end

  @doc """
  `check/3` for an approved target, judged under the Beginners' Workshop lock
  with the boundary clock read inside it: the current facts must still be the
  reviewed `expected` ones (`Dhc.Destinations.Enrichment.still_reviewed/3`),
  so an intervening reschedule, venue move, cancellation or destination edit
  is refused rather than overwritten.
  """
  @spec check_reviewed(facts() | nil, expected(), destination(), DateTime.t()) ::
          :change | :unchanged | {:refused, refusal()}
  def check_reviewed(facts, expected, proposed, %DateTime{} = now) do
    with :ok <- eligible(facts, now),
         :ok <- Enrichment.still_reviewed(facts, expected, proposed),
         do: Enrichment.outcome(facts.destination, proposed)
  end

  defp eligible(nil, _now), do: {:refused, :not_found}
  defp eligible(%{status: "cancelled"}, _now), do: {:refused, :cancelled}

  defp eligible(%{status: status}, _now) when status != "scheduled",
    do: {:refused, :not_eligible_status}

  defp eligible(facts, now) do
    if DateTime.compare(facts.starts_at, now) == :gt, do: :ok, else: {:refused, :started}
  end
end
