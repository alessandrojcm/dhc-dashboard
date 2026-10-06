defmodule Dhc.TrainingAnnouncements do
  @moduledoc """
  Committee-managed, scheduled Discord announcements about club training
  (ALE-317, ADR 0026). Sibling of `Dhc.WorkshopAnnouncements`; never a child
  of `Dhc.Workshops` or `Dhc.Discord`, and nothing here references
  `club_activities`.

  ## Vocabulary (from `CONTEXT.md`, verbatim)

  * **Training Announcement** — a committee-managed, scheduled Discord
    announcement about club training, of exactly one kind — `roll_call` or
    `sparring` — that is either weekly recurring or one-off. Its schedule is
    expressed in Europe/Dublin civil time and follows Irish daylight-saving
    changes; it starts and ends on the same local date. Its scheduled time is
    the moment it is posted; there is no separate lead time. Its dated
    projection is an Announcement Occurrence. Its kind never changes;
    schedule, default title/message, and `@everyone` changes are prospective.
  * **Announcement Occurrence** — one local-date instance of a Training
    Announcement, identified by that announcement and its Europe/Dublin date.
  * **Discord Announcement Delivery** — the one durable Discord progression
    for an Announcement Occurrence or a Holiday Announcement, identified by
    what it announces and its Europe/Dublin date.
  * **Announcement Disablement** — a reversible, open-ended pause of one
    Training Announcement.
  * **Announcement Suppression** — a committee decision that prevents
    delivery for either one Announcement Occurrence or every occurrence of
    one weekly Training Announcement in a finite, inclusive range of
    Europe/Dublin dates.
  * **Announcement Override** — a replacement title, message, or both for one
    Announcement Occurrence or a finite, inclusive range of one weekly
    Training Announcement's Europe/Dublin dates.
  * **Holiday Announcement** — the day-before and same-day "no training"
    Discord post for an Irish bank holiday, delivered to a fixed announcement
    channel regardless of which Training Announcements the holiday suppresses.

  ## Shape

  Pure projection lives in `Dhc.TrainingAnnouncements.Occurrences` and pure
  copy rendering in `Dhc.TrainingAnnouncements.Copy`; both are database-free
  so the worker, the read model and preview cannot disagree. Actor-first
  facade commands authorize a live, active committee principal before reading
  announcements. Schedule writes and their pending job commit together.
  The only module that may write Oban jobs is
  `Dhc.TrainingAnnouncements.Scheduling`. A due occurrence or Holiday
  Announcement becomes its one Evidence row only through
  `Dhc.TrainingAnnouncements.Execution.evaluate/2,3` (the optional third
  argument is the driving job); workers merely call it.
  """

  import Ecto.Query
  alias Dhc.Auth
  alias Dhc.Auth.Capabilities
  alias Dhc.Auth.Principal
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.Copy
  alias Dhc.TrainingAnnouncements.Exceptions
  alias Dhc.TrainingAnnouncements.Occurrences
  alias Dhc.TrainingAnnouncements.OccurrenceReads
  alias Dhc.TrainingAnnouncements.Scheduling
  alias Dhc.TrainingAnnouncements.Store

  @doc "Earliest Dublin date retained as delivery evidence and accepted by the window read model."
  @spec retention_horizon() :: Date.t()
  def retention_horizon(today \\ ClubCalendar.today()), do: Date.add(today, -400)

  def occurrence_window(actor_id, from, to, opts \\ []) do
    with :ok <- authorize(actor_id), do: OccurrenceReads.window(from, to, opts)
  end

  def get_occurrence(actor_id, id, date, opts \\ []) do
    with :ok <- authorize(actor_id),
         {:ok, announcement} <- Store.fetch(id),
         do: OccurrenceReads.get(announcement, date, opts)
  end

  def list_occurrences(actor_id, id, params, opts \\ []) do
    with :ok <- authorize(actor_id),
         {:ok, announcement} <- Store.fetch(id),
         do: OccurrenceReads.list(announcement, params, opts)
  end

  @doc "Creates a Training Announcement and its first future job atomically."
  def create(actor_id, attrs, opts \\ []) do
    with :ok <- authorize(actor_id) do
      prefetch_schedule(Announcement.create_changeset(%Announcement{}, attrs), opts)

      Repo.transaction(fn ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

        changeset =
          %Announcement{}
          |> Announcement.create_changeset(attrs)
          |> validate_send_time(now)
          |> validate_rendered_copy(now)

        announcement = persist!(Repo.insert(changeset))
        persist!(Scheduling.enqueue_next(announcement, now))
        {announcement, nil, now}
      end)
      |> with_warnings()
    end
  end

  @doc "Replaces the schedule for all future occurrences, together with the pending job."
  def update_schedule(actor_id, id, attrs, opts \\ []) do
    with :ok <- authorize(actor_id),
         {:ok, current} <- Store.fetch(id) do
      prefetch_schedule(
        Announcement.update_changeset(
          current,
          only(attrs, [:weekday, :one_off_date, :post_time, :kind])
        ),
        opts
      )

      Store.with_current(id, fn announcement ->
        # Read the production clock only after any claim wait or stale retry.
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        persist!(editable(announcement))
        persist!(schedule_editable(announcement))

        changeset =
          announcement
          |> Announcement.update_changeset(
            only(attrs, [:weekday, :one_off_date, :post_time, :kind])
          )
          |> validate_send_time(now)
          |> validate_rendered_copy(now)

        updated = persist!(Repo.update(changeset))
        persist!(Scheduling.reschedule(updated, now))
        {updated, announcement, now}
      end)
      |> with_warnings()
    end
  end

  defp prefetch_schedule(%{valid?: true} = changeset, opts) do
    Scheduling.prefetch_next(
      Ecto.Changeset.apply_changes(changeset),
      Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    )
  end

  defp prefetch_schedule(_changeset, _opts), do: :ok

  defp with_warnings({:ok, {announcement, previous, now}}) do
    # Warnings are advisory: holiday fetch-on-miss and projection happen after
    # the schedule/job commit, never while holding a write transaction open.
    {:ok,
     %{
       announcement: announcement,
       warnings: warnings(announcement, previous, now, holiday_dates(now))
     }}
  end

  defp with_warnings({:error, _} = error), do: error

  def list(actor_id, opts \\ []) do
    with :ok <- authorize(actor_id) do
      query = from(a in Announcement, order_by: [asc: a.created_at, asc: a.id])

      query =
        if Keyword.get(opts, :include_retired, false),
          do: query,
          else: where(query, [a], not a.retired)

      {:ok, Repo.all(query)}
    end
  end

  def get(actor_id, id) do
    with :ok <- authorize(actor_id), do: Store.fetch(id)
  end

  @doc "Updates default copy only; it cannot change the schedule or kind."
  def update_copy(actor_id, id, attrs, opts \\ []) do
    with :ok <- authorize(actor_id) do
      Store.with_current(id, fn announcement ->
        persist!(editable(announcement))

        announcement
        |> Announcement.update_changeset(
          only(attrs, [:title, :message, :mention_everyone, :kind])
        )
        |> validate_rendered_copy(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
        |> Repo.update()
        |> persist!()
      end)
    end
  end

  def disable(actor_id, id), do: set_enabled(actor_id, id, false)
  def enable(actor_id, id), do: set_enabled(actor_id, id, true)

  def suppress(actor_id, id, attrs, opts \\ []),
    do: create_exception(actor_id, id, :suppression, attrs, opts)

  def override(actor_id, id, attrs, opts \\ []),
    do: create_exception(actor_id, id, :override, attrs, opts)

  def list_suppressions(actor_id, id), do: list_exceptions(actor_id, id, :suppression)
  def list_overrides(actor_id, id), do: list_exceptions(actor_id, id, :override)

  def remove_suppression(actor_id, id, exception_id),
    do: remove_exception(actor_id, id, :suppression, exception_id)

  def remove_override(actor_id, id, exception_id),
    do: remove_exception(actor_id, id, :override, exception_id)

  defp create_exception(actor_id, id, kind, attrs, opts) do
    with :ok <- authorize(actor_id) do
      Store.with_current(id, fn announcement ->
        persist!(editable(announcement))
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        persist!(Exceptions.create(announcement, kind, attrs, now))
      end)
    end
  end

  defp list_exceptions(actor_id, id, kind) do
    with :ok <- authorize(actor_id),
         {:ok, announcement} <- Store.fetch(id),
         do: {:ok, Exceptions.list(announcement.id, kind)}
  end

  defp remove_exception(actor_id, id, kind, exception_id) do
    with :ok <- authorize(actor_id) do
      Store.with_current(id, fn announcement ->
        persist!(editable(announcement))
        persist!(Exceptions.remove(announcement.id, kind, exception_id))
      end)
    end
  end

  def retire(actor_id, id) do
    with :ok <- authorize(actor_id) do
      Store.with_current(id, fn announcement ->
        retired = persist!(Repo.update(Ecto.Changeset.change(announcement, retired: true)))
        Scheduling.cancel(announcement.id)
        retired
      end)
    end
  end

  def delete(actor_id, id) do
    with :ok <- authorize(actor_id) do
      Store.with_current(id, fn announcement ->
        persist!(deletable(announcement))
        Scheduling.cancel(announcement.id)
        persist!(Repo.delete(announcement))
      end)
    end
  end

  defp deletable(%{first_attempted_at: nil}), do: :ok
  defp deletable(_announcement), do: {:error, :attempted}

  @doc "Stateless copy preview: validates and renders without writing or posting."
  def preview_copy(actor_id, attrs) do
    with :ok <- authorize(actor_id) do
      types = %{
        kind: :string,
        title: :string,
        message: :string,
        mention_everyone: :boolean,
        date: :date
      }

      changeset =
        {%{mention_everyone: false}, types}
        |> Ecto.Changeset.cast(attrs, Map.keys(types))
        |> Ecto.Changeset.validate_required([:kind, :title, :message, :date, :mention_everyone])
        |> Ecto.Changeset.validate_inclusion(:kind, ~w(roll_call sparring))

      with {:ok, copy} <- Ecto.Changeset.apply_action(changeset, :preview) do
        Copy.render(copy, copy.date)
      end
    end
  end

  defp set_enabled(actor_id, id, enabled) do
    with :ok <- authorize(actor_id) do
      Store.with_current(id, fn announcement ->
        persist!(editable(announcement))
        announcement |> Ecto.Changeset.change(enabled: enabled) |> Repo.update() |> persist!()
      end)
    end
  end

  defp holiday_dates(now) do
    today = ClubCalendar.on_date(now)
    {:ok, holidays} = ClubCalendar.holidays_between(today, Date.add(today, 61))
    MapSet.new(holidays, & &1.date)
  end

  defp warnings(announcement, previous, now, holidays) do
    today = ClubCalendar.on_date(now)
    last = Date.add(today, 61)

    opts = [
      today: today,
      now_time:
        now
        |> DateTime.shift_zone!(ClubCalendar.zone(), Tz.TimeZoneDatabase)
        |> DateTime.to_time(),
      holidays: holidays
    ]

    other_announcements =
      Repo.all(from(a in Announcement, where: not a.retired and a.id != ^announcement.id))

    [entry | others] = Store.entries([announcement | other_announcements])

    collision = Occurrences.warnings_for_create(entry, others, today, last, opts)

    intersection =
      if previous,
        do:
          Occurrences.warnings_for_schedule_change(
            previous,
            announcement,
            entry.suppressions,
            entry.overrides,
            today,
            last,
            opts
          ),
        else: []

    collision ++ intersection
  end

  defp validate_rendered_copy(%{valid?: false} = changeset, _now), do: changeset

  defp validate_rendered_copy(changeset, now) do
    announcement = Ecto.Changeset.apply_changes(changeset)
    today = ClubCalendar.on_date(now)
    # A full civil year includes the longest date/weekday expansions; one-offs
    # validate their actual date. This does not depend on disablement or holidays.
    dates =
      if announcement.one_off_date,
        do: [announcement.one_off_date],
        else:
          Enum.filter(
            Date.range(today, Date.add(today, 366)),
            &(Date.day_of_week(&1) == announcement.weekday)
          )

    Enum.reduce_while(dates, changeset, fn date, changeset ->
      case Copy.render(announcement, date) do
        {:ok, _} ->
          {:cont, changeset}

        {:error, errors} ->
          {:halt, Ecto.Changeset.add_error(changeset, :message, Enum.join(errors, ", "))}
      end
    end)
  end

  defp editable(%{retired: true}), do: {:error, :retired}
  defp editable(_), do: :ok

  defp schedule_editable(%{weekday: nil, first_attempted_at: at}) when not is_nil(at),
    do: {:error, :delivery_started}

  defp schedule_editable(_), do: :ok

  defp validate_send_time(%{valid?: false} = changeset, _now), do: changeset

  defp validate_send_time(changeset, now) do
    announcement = Ecto.Changeset.apply_changes(changeset)
    today = ClubCalendar.on_date(now)

    date =
      announcement.one_off_date ||
        Date.add(today, Integer.mod(announcement.weekday - Date.day_of_week(today), 7))

    if DateTime.compare(ClubCalendar.to_utc(date, announcement.post_time), now) == :gt do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :post_time,
        "the first send instant has elapsed; choose a future Dublin date or time"
      )
    end
  end

  defp only(attrs, fields) do
    Map.take(attrs, fields ++ Enum.map(fields, &Atom.to_string/1))
  end

  defp authorize(actor_id) when is_binary(actor_id) do
    with {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
         {:ok, projection} <- Auth.load_session_principal(%Principal{id: actor_id}),
         :ok <- Capabilities.authorize(projection, :"training_announcements.manage") do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(_actor), do: {:error, :forbidden}

  defp persist!({:ok, result}), do: result
  defp persist!(:ok), do: :ok
  defp persist!({:error, reason}), do: Repo.rollback(reason)
end
