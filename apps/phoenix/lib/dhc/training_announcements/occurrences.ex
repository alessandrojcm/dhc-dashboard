defmodule Dhc.TrainingAnnouncements.Occurrences do
  @moduledoc """
  Pure projection of Announcement Occurrences over a date window (ALE-322).

  Given a Training Announcement, its Announcement Suppressions and
  Announcement Overrides, and the Irish bank-holiday set, yields each
  Announcement Occurrence with its resolved outcome and precedence chain.
  Shared by the worker, the read model and preview so they cannot disagree —
  the `Dhc.Inventory.LoanPolicy` analogue.

  Resolution order per occurrence (ALE-308, renamed by ALE-311):

  * `roll_call`: bank holiday → Announcement Disablement →
    Announcement Suppression → Announcement Override → announcement defaults.
  * `sparring`: the same without the holiday step — Sunday sparring is
    confirmed with the venue and is never assumed cancelled.

  A bank holiday cannot be overridden, and a Suppression hides Override copy
  without deleting it: suppressed Overrides stay stored but dormant.

  Exceptions bind to absolute Europe/Dublin dates across schedule edits: an
  exception whose range covers no occurrence is dormant and may apply again
  after a later edit. The not-elapsed rule drops the elapsed slot of today
  (a send instant must be strictly after now), so the window agrees with what
  the worker will actually do.

  Each occurrence carries the evaluated precedence `chain` — the steps
  actually checked, in order, up to and including the decisive one — plus
  `decided_by`, so the inspector can show *why* an occurrence resolved the
  way it did without re-deriving it. A skipped occurrence's chain is
  therefore a prefix of the full order (e.g. a holiday skip is `[:holiday]`);
  only a `:defaults` post walks the whole order.

  When several Suppressions cover one date the earliest wins; Overlapping
  Overrides cannot exist (the database rejects them), so at most one Override
  ever covers a date.

  Every function here is pure. `today`, the Dublin civil `now_time`, and the
  holiday set are always parameters — resolving the club's calendar day is
  the caller's job, so one window judges every row against one clock.

  Glossary (`CONTEXT.md`): "One local-date instance of a Training
  Announcement, identified by that announcement and its Europe/Dublin date."
  """

  @type outcome ::
          :post | :post_override | :skipped_holiday | :skipped_disabled | :skipped_suppressed

  @type occurrence :: %{
          announcement_id: String.t(),
          date: Date.t(),
          kind: String.t(),
          outcome: outcome(),
          decided_by: :holiday | :disablement | :suppression | :override | :defaults,
          chain: [:holiday | :disablement | :suppression | :override | :defaults],
          title: String.t(),
          message: String.t(),
          mention_everyone: boolean(),
          applied_suppression_id: String.t() | nil,
          applied_override_id: String.t() | nil
        }

  @type announcement :: %{
          required(:id) => String.t(),
          required(:kind) => String.t(),
          required(:weekday) => 1..7 | nil,
          required(:one_off_date) => Date.t() | nil,
          required(:post_time) => Time.t(),
          required(:title) => String.t(),
          required(:message) => String.t(),
          required(:mention_everyone) => boolean(),
          required(:enabled) => boolean()
        }

  @type suppression :: %{
          required(:id) => String.t(),
          required(:from_date) => Date.t(),
          required(:to_date) => Date.t()
        }
  @type override :: %{
          required(:id) => String.t(),
          required(:from_date) => Date.t(),
          required(:to_date) => Date.t(),
          optional(:title) => String.t() | nil,
          optional(:message) => String.t() | nil
        }

  @doc """
  Projects every occurrence of `announcement` in the inclusive window
  `from..to`, omitting dates with no scheduled occurrence and elapsed slots.

  Options: `:suppressions`, `:overrides`, `:holidays` (a `MapSet` of
  Europe/Dublin dates), `:today` (required), `:now_time` (required Dublin
  civil time for the not-elapsed rule).
  """
  @spec window(announcement(), Date.t(), Date.t(), keyword()) :: [occurrence()]
  def window(announcement, %Date{} = from, %Date{} = to, opts) do
    from
    |> Date.range(to)
    |> Enum.flat_map(fn date ->
      case resolve(announcement, date, opts) do
        nil -> []
        occurrence -> [occurrence]
      end
    end)
  end

  @doc """
  Resolves a single date to its occurrence, or `nil` when nothing is
  scheduled that date or the slot has already elapsed today.
  """
  @spec resolve(announcement(), Date.t(), keyword()) :: occurrence() | nil
  def resolve(announcement, %Date{} = date, opts) do
    today = Keyword.fetch!(opts, :today)
    now_time = Keyword.fetch!(opts, :now_time)
    suppressions = Keyword.get(opts, :suppressions, [])
    overrides = Keyword.get(opts, :overrides, [])
    holidays = Keyword.get(opts, :holidays, MapSet.new())

    with true <- scheduled_on?(announcement, date),
         false <- elapsed?(announcement, date, today, now_time) do
      decide(announcement, date, suppressions, overrides, holidays)
    else
      _ -> nil
    end
  end

  @doc """
  Finds slots where two or more announcements would post together.

  Each entry is `%{announcement:, suppressions: [], overrides: []}`; only
  posting outcomes (`:post`, `:post_override`) collide — a suppressed or
  skipped occurrence frees its slot. Options: `:holidays`, `:today`,
  `:now_time` (required).
  """
  @spec slot_collisions([map()], Date.t(), Date.t(), keyword()) :: [
          %{date: Date.t(), post_time: Time.t(), announcement_ids: [String.t()]}
        ]
  def slot_collisions(entries, %Date{} = from, %Date{} = to, opts) do
    entries
    |> Enum.flat_map(fn entry ->
      entry
      |> posting_occurrences(from, to, opts)
      |> Enum.map(fn occurrence ->
        {occurrence.date, entry.announcement.post_time, entry.announcement.id}
      end)
    end)
    |> Enum.group_by(fn {date, post_time, _id} -> {date, post_time} end, fn {_d, _t, id} -> id end)
    |> Enum.flat_map(fn {{date, post_time}, ids} ->
      unique = Enum.uniq(ids)

      if match?([_, _ | _], unique) do
        [%{date: date, post_time: post_time, announcement_ids: Enum.sort(unique)}]
      else
        []
      end
    end)
    |> Enum.sort_by(fn %{date: date, post_time: time} -> {date, time} end)
  end

  @doc """
  Computes the create/update warnings for one announcement against the
  others: `[:slot_collision]` when it would post in an occupied slot.
  """
  @spec warnings_for_create(map(), [map()], Date.t(), Date.t(), keyword()) :: [:slot_collision]
  def warnings_for_create(entry, others, %Date{} = from, %Date{} = to, opts) do
    collisions = slot_collisions([entry | others], from, to, opts)
    id = entry.announcement.id

    if Enum.any?(collisions, fn %{announcement_ids: ids} -> id in ids end) do
      [:slot_collision]
    else
      []
    end
  end

  @doc """
  Warns when a schedule edit changes which future exceptions still
  intersect occurrences: `[:exception_intersection_changed]` or `[]`.
  """
  @spec warnings_for_schedule_change(
          announcement(),
          announcement(),
          [suppression()],
          [override()],
          Date.t(),
          Date.t(),
          keyword()
        ) ::
          [:exception_intersection_changed]
  def warnings_for_schedule_change(
        old_announcement,
        new_announcement,
        suppressions,
        overrides,
        %Date{} = from,
        %Date{} = to,
        opts
      ) do
    before = intersecting_exceptions(old_announcement, suppressions, overrides, from, to, opts)

    after_change =
      intersecting_exceptions(new_announcement, suppressions, overrides, from, to, opts)

    if before == after_change, do: [], else: [:exception_intersection_changed]
  end

  defp scheduled_on?(%{weekday: weekday}, date) when is_integer(weekday) do
    Date.day_of_week(date) == weekday
  end

  defp scheduled_on?(%{weekday: nil, one_off_date: %Date{} = one_off}, date) do
    Date.compare(date, one_off) == :eq
  end

  defp elapsed?(%{post_time: post_time}, date, today, now_time) do
    case Date.compare(date, today) do
      :lt -> true
      :gt -> false
      :eq -> Time.compare(post_time, now_time) != :gt
    end
  end

  defp decide(announcement, date, suppressions, overrides, holidays) do
    steps =
      if announcement.kind == "roll_call",
        do: [:holiday, :disablement, :suppression, :override, :defaults],
        else: [:disablement, :suppression, :override, :defaults]

    do_decide(announcement, date, suppressions, overrides, holidays, steps, [])
  end

  defp do_decide(
         announcement,
         date,
         suppressions,
         overrides,
         holidays,
         [:holiday | rest],
         checked
       ) do
    if MapSet.member?(holidays, date) do
      outcome(announcement, date, :skipped_holiday, :holiday, [:holiday], nil, nil)
    else
      do_decide(announcement, date, suppressions, overrides, holidays, rest, [:holiday | checked])
    end
  end

  defp do_decide(
         announcement,
         date,
         suppressions,
         overrides,
         holidays,
         [:disablement | rest],
         checked
       ) do
    if announcement.enabled do
      do_decide(announcement, date, suppressions, overrides, holidays, rest, [
        :disablement | checked
      ])
    else
      outcome(
        announcement,
        date,
        :skipped_disabled,
        :disablement,
        Enum.reverse([:disablement | checked]),
        nil,
        nil
      )
    end
  end

  defp do_decide(
         announcement,
         date,
         suppressions,
         overrides,
         holidays,
         [:suppression | rest],
         checked
       ) do
    case covering(suppressions, date) do
      nil ->
        do_decide(announcement, date, suppressions, overrides, holidays, rest, [
          :suppression | checked
        ])

      suppression ->
        outcome(
          announcement,
          date,
          :skipped_suppressed,
          :suppression,
          Enum.reverse([:suppression | checked]),
          suppression.id,
          nil
        )
    end
  end

  defp do_decide(
         announcement,
         date,
         suppressions,
         overrides,
         holidays,
         [:override | rest],
         checked
       ) do
    case covering(overrides, date) do
      nil ->
        do_decide(announcement, date, suppressions, overrides, holidays, rest, [
          :override | checked
        ])

      override ->
        outcome(
          announcement,
          date,
          :post_override,
          :override,
          Enum.reverse([:override | checked]),
          nil,
          override.id,
          override
        )
    end
  end

  defp do_decide(announcement, date, _suppressions, _overrides, _holidays, [:defaults], checked) do
    outcome(announcement, date, :post, :defaults, Enum.reverse([:defaults | checked]), nil, nil)
  end

  defp outcome(
         announcement,
         date,
         result,
         decided_by,
         chain,
         suppression_id,
         override_id,
         override \\ %{}
       ) do
    %{
      announcement_id: announcement.id,
      date: date,
      kind: announcement.kind,
      outcome: result,
      decided_by: decided_by,
      chain: chain,
      title: Map.get(override, :title) || announcement.title,
      message: Map.get(override, :message) || announcement.message,
      mention_everyone: announcement.mention_everyone,
      applied_suppression_id: suppression_id,
      applied_override_id: override_id
    }
  end

  defp covering(exceptions, date) do
    exceptions
    |> Enum.filter(&covers?(&1, date))
    |> Enum.min_by(& &1.from_date, Date, fn -> nil end)
  end

  defp covers?(%{from_date: from, to_date: to}, date) do
    Date.compare(date, from) != :lt and Date.compare(date, to) != :gt
  end

  defp posting_occurrences(entry, from, to, opts) do
    entry
    |> Map.get(:suppressions, [])
    |> then(fn suppressions ->
      window(
        entry.announcement,
        from,
        to,
        Keyword.merge(opts,
          suppressions: suppressions,
          overrides: Map.get(entry, :overrides, [])
        )
      )
    end)
    |> Enum.filter(fn %{outcome: outcome} -> outcome in [:post, :post_override] end)
  end

  defp intersecting_exceptions(announcement, suppressions, overrides, from, to, opts) do
    dates =
      from
      |> Date.range(to)
      |> Enum.filter(fn date ->
        scheduled_on?(announcement, date) and
          not elapsed?(
            announcement,
            date,
            Keyword.fetch!(opts, :today),
            Keyword.fetch!(opts, :now_time)
          )
      end)
      |> MapSet.new()

    %{
      suppression_ids:
        suppressions
        |> Enum.filter(fn %{from_date: s_from, to_date: s_to} ->
          Enum.any?(dates, fn date ->
            Date.compare(date, s_from) != :lt and Date.compare(date, s_to) != :gt
          end)
        end)
        |> Enum.map(& &1.id)
        |> MapSet.new(),
      override_ids:
        overrides
        |> Enum.filter(fn %{from_date: s_from, to_date: s_to} ->
          Enum.any?(dates, fn date ->
            Date.compare(date, s_from) != :lt and Date.compare(date, s_to) != :gt
          end)
        end)
        |> Enum.map(& &1.id)
        |> MapSet.new()
    }
  end
end
