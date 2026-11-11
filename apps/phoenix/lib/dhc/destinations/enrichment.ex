defmodule Dhc.Destinations.Enrichment do
  @moduledoc """
  The domain-neutral half of a reviewed same-Venue destination enrichment
  (ALE-443/ALE-444): how a proposed destination compares with the stored one,
  and whether a source's current facts are still the ones a reviewer approved.

  Each source context keeps its own eligibility rule (statuses, archive,
  start), storage, lock and command; this module judges only the shared fact
  shape — `label`, `status`, Dublin civil `date`/`start_time`/`end_time` and
  `destination` with the `fields/0` keys — so a regular
  Workshop and a Beginners' Workshop are judged identically without either
  context reading the other (ADR 0029).
  """

  alias Dhc.Destinations

  # The reviewed destination: the manual text plus the selected place
  # (ALE-442). A reviewed mapping only ever proposes manual text
  # (`destination_place_id: nil`), so a Google-selected destination is never
  # "absent" and is refused as a conflict rather than overwritten.
  @fields Destinations.fields()

  @type destination :: %{
          destination_text: String.t() | nil,
          destination_place_id: String.t() | nil
        }

  @doc """
  The keys of a reviewed destination: `Dhc.Destinations.fields/0`
  (`destination_text` and `destination_place_id`).
  """
  @spec fields() :: [atom()]
  def fields, do: @fields

  @typedoc """
  The reviewed current facts an approved target names: the short label, the
  status and Dublin civil schedule, and the destination the reviewer saw.
  """
  @type expected :: %{
          label: String.t(),
          status: String.t(),
          date: Date.t(),
          start_time: Time.t(),
          end_time: Time.t() | nil,
          destination: destination()
        }

  @type stale :: :label_changed | :rescheduled | :status_changed | :destination_changed

  @doc """
  Whether a source's current `facts` are still the reviewed `expected` ones.

  A different label means the source may have moved Venue, and a different
  schedule, status or destination means the review is stale; neither is
  overwritten. A destination that already is the proposal is the reviewed end
  state, so repeating an applied plan (or a duplicate driver) is not stale.
  """
  @spec still_reviewed(map(), expected(), destination()) :: :ok | {:refused, stale()}
  def still_reviewed(facts, expected, proposed) do
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

  @doc """
  How `proposed` compares with the `current` stored destination:

    * `:unchanged` — the stored destination already is the proposal;
    * `:change` — no destination is stored (neither text nor a place), so
      the proposal fills it;
    * `{:refused, :destination_conflict}` — different text or a selected
      place is stored: a different destination, which the source's ordinary
      editor owns.
  """
  @spec outcome(destination(), destination()) ::
          :change | :unchanged | {:refused, :destination_conflict}
  def outcome(current, proposed) do
    cond do
      current == proposed -> :unchanged
      fills_absent?(current, proposed) -> :change
      true -> {:refused, :destination_conflict}
    end
  end

  defp fills_absent?(current, proposed) do
    Enum.all?(@fields, fn field ->
      value = Map.fetch!(current, field)
      is_nil(value) or value == Map.fetch!(proposed, field)
    end)
  end
end
