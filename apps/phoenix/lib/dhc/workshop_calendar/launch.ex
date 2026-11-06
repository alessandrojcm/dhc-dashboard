defmodule Dhc.WorkshopCalendar.Launch do
  @moduledoc "Operator preview and explicit, target-bound launch. No Google I/O."
  import Ecto.Query

  alias Dhc.BeginnersWorkshops
  alias Dhc.Repo
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Control, Event, Recipients, Store, Sync}
  alias Dhc.Workshops

  @owners [{:workshop, Workshops}, {:beginners_workshop, BeginnersWorkshops}]

  def preview(opts \\ []) do
    now = clock(opts).()
    sources = sources(now)
    events = Repo.all(Event)

    rows =
      sources
      |> Enum.map(fn {kind, _owner, source} -> {kind, source.id} end)
      |> Kernel.++(cleanup_sources(events))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn {kind, id} -> preview_source(kind, id, events, now) end)

    blockers = schedule_blockers(sources)
    config_issues = configuration_issues()

    %{
      environment: Keyword.get(WorkshopCalendar.config(), :environment),
      active: active?(),
      configuration_issues: config_issues,
      blockers: blockers,
      ready: blockers == [] and config_issues == [],
      workshops: rows
    }
  end

  def activate(target, opts \\ [])

  def activate(target, opts) when target in ["isolated", "production"] do
    with :ok <- configured_target(target) do
      Repo.transaction(fn -> activate_locked(target, opts) end)
      |> enqueue_after_commit()
    end
  end

  def activate(_target, _opts), do: {:error, :invalid_environment}

  defp activate_locked(target, opts) do
    control = Repo.one!(from(c in Control, where: c.id == 1, lock: "FOR UPDATE"))
    sources = sources(clock(opts).())
    validate_schedules!(sources)

    # Source owners re-read under their existing locks. The preview is never
    # accepted as input, and no recipient/address is copied into a job.
    Enum.each(sources, &materialize!(&1, opts))

    control
    |> Ecto.Changeset.change(
      activation_key: activation_key(),
      activated_at: control.activated_at || timestamp(clock(opts).())
    )
    |> Repo.update!()

    %{environment: target, sources: length(sources)}
  end

  defp validate_schedules!(sources) do
    case schedule_blockers(sources) do
      [] -> :ok
      blockers -> Repo.rollback({:invalid_schedules, blockers})
    end
  end

  defp materialize!({_kind, owner, source}, opts) do
    case owner.materialize_calendar_launch(source.id, opts) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def active? do
    key = activation_key()
    not is_nil(key) and match?(%Control{activation_key: ^key}, Repo.get(Control, 1))
  end

  defp enqueue_after_commit({:ok, _} = result) do
    WorkshopCalendar.repair()
    result
  end

  defp enqueue_after_commit(error), do: error

  defp sources(now) do
    for {kind, owner} <- @owners,
        source <- owner.calendar_launch_sources(now),
        do: {kind, owner, source}
  end

  defp schedule_blockers(sources) do
    for {kind, _owner, source} <- sources,
        issue = schedule_issue(source),
        not is_nil(issue),
        do: %{source_kind: kind, source_id: source.id, issue: issue}
  end

  defp schedule_issue(%{end_date: nil}), do: :missing_end_time

  defp schedule_issue(%{start_date: %DateTime{} = start, end_date: %DateTime{} = finish}) do
    if DateTime.compare(finish, start) != :gt, do: :invalid_schedule
  end

  defp schedule_issue(_), do: :invalid_schedule

  defp cleanup_sources(events) do
    for event <- events,
        not event.removal_completed,
        cleanup?(event),
        do: {source_kind(event.source_kind), event.source_id}
  end

  defp cleanup?(%{deleted: true}), do: true

  defp cleanup?(%{audience: "participant"} = event) do
    Enum.any?(Recipients.list(event), fn row ->
      row.privacy_pending or
        (not row.active and not is_nil(row.recipient) and
           row.removed_generation != event.generation)
    end)
  end

  defp cleanup?(_event), do: false

  defp preview_source(kind, id, events, now) do
    owner = Keyword.fetch!(@owners, kind)
    source = owner.calendar_projection(id)
    places = owner.calendar_launch_places(id)
    committee = find_event(events, kind, id, "committee")
    participant = find_event(events, kind, id, "participant")
    recipients = recipient_preview(participant, places, source, now)

    %{
      source_kind: kind,
      source_id: id,
      source: source,
      issue: if(source, do: schedule_issue(source)),
      committee: audience_preview(committee, kind, id, "committee", source, now),
      participant:
        audience_preview(participant, kind, id, "participant", source, now)
        |> participant_intentions(recipients)
    }
  end

  defp participant_intentions(preview, recipients) do
    action =
      if preview.action in [:create, :create_if_eligible_recipients] and
           not Enum.any?(recipients, &(&1.action in [:invite, :retain])),
         do: :not_required,
         else: preview.action

    Map.merge(preview, %{action: action, recipients: recipients})
  end

  defp find_event(events, kind, id, audience),
    do:
      Enum.find(events, fn event ->
        event.source_kind == to_string(kind) and event.source_id == id and
          event.audience == audience
      end)

  defp audience_preview(event, kind, id, audience, source, now) do
    identity =
      event ||
        %{
          source_kind: to_string(kind),
          audience: audience,
          event_id: Store.event_id(kind, id, audience, 0)
        }

    projection = if source && is_nil(schedule_issue(source)), do: Sync.preview(identity, source)

    %{
      action: audience_action(event, audience, source, projection, now),
      projection: projection,
      failure: event && event.failure
    }
  end

  defp audience_action(_event, _audience, nil, _projection, _now), do: :remove

  defp audience_action(_event, "participant", %{status: "cancelled"}, _projection, _now),
    do: :remove

  defp audience_action(_event, _audience, _source, nil, _now), do: :blocked

  defp audience_action(event, audience, source, projection, now) do
    if DateTime.compare(source.end_date, now) != :gt,
      do: :preserve_history,
      else: live_action(event, audience, projection)
  end

  defp live_action(nil, "participant", _projection), do: :create_if_eligible_recipients
  defp live_action(nil, _audience, _projection), do: :create
  defp live_action(%{acknowledged: nil}, _audience, _projection), do: :create

  defp live_action(event, _audience, projection) do
    if Map.drop(event.acknowledged, ["attendees"]) == Map.drop(projection, ["attendees"]),
      do: :retain,
      else: :update
  end

  defp recipient_preview(event, places, source, now) do
    retained = if event, do: Recipients.list(event), else: []
    retained_ids = MapSet.new(retained, & &1.place_id)
    eligible_ids = MapSet.new(places, & &1.place_id)

    existing =
      Enum.map(retained, fn row ->
        active? = row.active and MapSet.member?(eligible_ids, row.place_id)

        %{
          place_id: row.place_id,
          recipient: row.recipient,
          retained: true,
          action: recipient_action(row, active?, event.generation, source, now),
          issue: recipient_issue(row.recipient, row.failure)
        }
      end)

    additions =
      for place <- places, not MapSet.member?(retained_ids, place.place_id) do
        issue = recipient_issue(place.recipient, nil)

        Map.merge(place, %{
          retained: false,
          action: addition_action(issue, source, now),
          issue: issue
        })
      end

    Enum.sort_by(existing ++ additions, & &1.place_id)
  end

  defp recipient_action(%{privacy_pending: true}, _active, _generation, _source, _now),
    do: :privacy_cleanup

  defp recipient_action(_row, _active, _generation, nil, _now), do: :remove

  defp recipient_action(_row, _active, _generation, %{status: "cancelled"}, _now),
    do: :remove

  defp recipient_action(%{recipient: nil}, false, _generation, _source, _now),
    do: :retain_removed

  defp recipient_action(row, false, generation, _source, _now) do
    if row.removed_generation != generation, do: :remove, else: :retain_removed
  end

  defp recipient_action(row, true, generation, source, now) do
    cond do
      not is_nil(recipient_issue(row.recipient, row.failure)) -> :blocked
      row.invited_generation == generation -> :retain
      is_nil(source.end_date) -> :blocked
      DateTime.compare(source.end_date, now) != :gt -> :preserve_history
      true -> :invite
    end
  end

  defp addition_action(issue, source, now) do
    cond do
      is_nil(source) or source.status == "cancelled" -> :excluded
      not is_nil(issue) or not is_nil(schedule_issue(source)) -> :blocked
      DateTime.compare(source.start_date, now) != :gt -> :excluded
      true -> :invite
    end
  end

  defp recipient_issue(nil, _failure), do: :missing_recipient
  defp recipient_issue("", _failure), do: :missing_recipient
  defp recipient_issue(_recipient, failure) when not is_nil(failure), do: failure

  defp recipient_issue(recipient, _failure) do
    unless Recipients.valid?(recipient), do: :invalid_recipient
  end

  defp configured_target(target) do
    cond do
      Keyword.get(WorkshopCalendar.config(), :environment) != target ->
        {:error, :environment_mismatch}

      configuration_issues() != [] ->
        {:error, :configuration}

      true ->
        :ok
    end
  end

  defp configuration_issues do
    config = WorkshopCalendar.config()

    if Keyword.get(config, :environment) in ["isolated", "production"] and
         Sync.validate_configuration() == :ok and
         Enum.all?([:client_id, :client_secret, :refresh_token], &nonempty?(config[&1])),
       do: [],
       else: [:configuration]
  end

  defp activation_key do
    config = WorkshopCalendar.config()

    if configuration_issues() == [] do
      [
        config[:environment],
        config[:committee_calendar_id],
        config[:participant_calendar_id],
        config[:client_id]
      ]
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp clock(opts), do: Keyword.get(opts, :clock, &DateTime.utc_now/0)
  defp source_kind("workshop"), do: :workshop
  defp source_kind("beginners_workshop"), do: :beginners_workshop

  defp timestamp(now),
    do: now |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)
end
