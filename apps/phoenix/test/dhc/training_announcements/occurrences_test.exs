defmodule Dhc.TrainingAnnouncements.OccurrencesTest do
  use ExUnit.Case, async: true

  alias Dhc.TrainingAnnouncements.Occurrences

  @thursday_2025_09_25 ~D[2025-09-25]
  @thursday_2025_10_02 ~D[2025-10-02]

  defp announcement(overrides \\ %{}) do
    Map.merge(
      %{
        id: "ann-1",
        kind: "roll_call",
        weekday: 4,
        one_off_date: nil,
        post_time: ~T[19:00:00],
        title: "Roll call {{date}}",
        message: "Who is coming?",
        mention_everyone: true,
        enabled: true
      },
      overrides
    )
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [today: ~D[2025-09-20], now_time: ~T[10:00:00], holidays: MapSet.new()],
      overrides
    )
  end

  defp suppression(id, from, to \\ nil) do
    %{id: id, from_date: from, to_date: to || from}
  end

  defp override(id, from, to \\ nil, title \\ "Special", message \\ nil) do
    %{id: id, from_date: from, to_date: to || from, title: title, message: message}
  end

  describe "window/4 weekly projection" do
    test "projects each matching weekday as a posting occurrence with the full chain" do
      occurrences =
        Occurrences.window(
          announcement(),
          @thursday_2025_09_25,
          @thursday_2025_10_02,
          opts()
        )

      assert [%{date: @thursday_2025_09_25}, %{date: @thursday_2025_10_02}] = occurrences

      for occurrence <- occurrences do
        assert occurrence.outcome == :post
        assert occurrence.decided_by == :defaults
        assert occurrence.chain == [:holiday, :disablement, :suppression, :override, :defaults]
        assert occurrence.title == "Roll call {{date}}"
        assert occurrence.mention_everyone == true
        assert occurrence.applied_suppression_id == nil
        assert occurrence.applied_override_id == nil
      end
    end

    test "sparring occurrences skip the holiday step in the chain" do
      [occurrence] =
        Occurrences.window(
          announcement(%{kind: "sparring", weekday: 7}),
          ~D[2025-09-28],
          ~D[2025-09-28],
          opts()
        )

      assert occurrence.outcome == :post
      assert occurrence.chain == [:disablement, :suppression, :override, :defaults]
    end

    test "projects across both Dublin DST transitions by weekday" do
      # DST starts Sunday 29 March 2026; ends Sunday 25 October 2026.
      spring =
        Occurrences.window(announcement(), ~D[2026-03-23], ~D[2026-04-05], opts())

      assert Enum.map(spring, & &1.date) == [~D[2026-03-26], ~D[2026-04-02]]

      autumn =
        Occurrences.window(announcement(), ~D[2026-10-19], ~D[2026-11-01], opts())

      assert Enum.map(autumn, & &1.date) == [~D[2026-10-22], ~D[2026-10-29]]
    end
  end

  describe "window/4 one-off projection" do
    test "projects exactly its date when inside the window" do
      ann = announcement(%{weekday: nil, one_off_date: ~D[2025-09-27]})

      assert [%{date: ~D[2025-09-27], outcome: :post}] =
               Occurrences.window(ann, ~D[2025-09-20], ~D[2025-09-30], opts())
    end

    test "projects nothing when its date is outside the window" do
      ann = announcement(%{weekday: nil, one_off_date: ~D[2025-10-15]})

      assert [] = Occurrences.window(ann, ~D[2025-09-20], ~D[2025-09-30], opts())
    end
  end

  describe "not-elapsed rule" do
    test "excludes past dates from the window" do
      occurrences =
        Occurrences.window(
          announcement(),
          ~D[2025-09-18],
          @thursday_2025_09_25,
          opts()
        )

      assert [%{date: @thursday_2025_09_25}] = occurrences
    end

    test "excludes today's slot once its send instant has passed" do
      occurrences =
        Occurrences.window(
          announcement(%{weekday: 6}),
          ~D[2025-09-20],
          ~D[2025-09-20],
          opts(today: ~D[2025-09-20], now_time: ~T[19:00:00])
        )

      assert [] = occurrences
    end

    test "keeps today's slot while its send instant is strictly in the future" do
      [occurrence] =
        Occurrences.window(
          announcement(%{weekday: 6}),
          ~D[2025-09-20],
          ~D[2025-09-20],
          opts(today: ~D[2025-09-20], now_time: ~T[18:59:59])
        )

      assert occurrence.date == ~D[2025-09-20]
    end
  end

  describe "precedence" do
    test "a bank holiday suppresses a roll call and keeps overrides dormant" do
      holidays = MapSet.new([@thursday_2025_09_25])

      [occurrence] =
        Occurrences.window(
          announcement(),
          @thursday_2025_09_25,
          @thursday_2025_09_25,
          opts(
            holidays: holidays,
            suppressions: [],
            overrides: [override("ovr-1", @thursday_2025_09_25)]
          )
        )

      assert occurrence.outcome == :skipped_holiday
      assert occurrence.decided_by == :holiday
      assert occurrence.chain == [:holiday]
      assert occurrence.title == "Roll call {{date}}"
      assert occurrence.applied_override_id == nil
    end

    test "a bank holiday never suppresses sparring" do
      holidays = MapSet.new([~D[2025-09-28]])

      [occurrence] =
        Occurrences.window(
          announcement(%{kind: "sparring", weekday: 7}),
          ~D[2025-09-28],
          ~D[2025-09-28],
          opts(holidays: holidays)
        )

      assert occurrence.outcome == :post
    end

    test "a disabled announcement skips after the holiday check" do
      [occurrence] =
        Occurrences.window(
          announcement(%{enabled: false}),
          @thursday_2025_09_25,
          @thursday_2025_09_25,
          opts()
        )

      assert occurrence.outcome == :skipped_disabled
      assert occurrence.decided_by == :disablement
      assert occurrence.chain == [:holiday, :disablement]
    end

    test "a suppression range skips every covered occurrence" do
      [first, second] =
        Occurrences.window(
          announcement(),
          @thursday_2025_09_25,
          @thursday_2025_10_02,
          opts(suppressions: [suppression("sup-1", @thursday_2025_09_25, @thursday_2025_10_02)])
        )

      assert first.outcome == :skipped_suppressed
      assert first.decided_by == :suppression
      assert first.applied_suppression_id == "sup-1"
      assert second.outcome == :skipped_suppressed
    end

    test "a suppression hides the override copy without deleting it" do
      [occurrence] =
        Occurrences.window(
          announcement(),
          @thursday_2025_09_25,
          @thursday_2025_09_25,
          opts(
            suppressions: [suppression("sup-1", @thursday_2025_09_25)],
            overrides: [override("ovr-1", @thursday_2025_09_25, nil, "Special night")]
          )
        )

      assert occurrence.outcome == :skipped_suppressed
      assert occurrence.title == "Roll call {{date}}"
      assert occurrence.applied_override_id == nil
    end

    test "an override posts with replaced copy and falls back per field" do
      [occurrence] =
        Occurrences.window(
          announcement(),
          @thursday_2025_09_25,
          @thursday_2025_09_25,
          opts(overrides: [override("ovr-1", @thursday_2025_09_25, nil, "Special", nil)])
        )

      assert occurrence.outcome == :post_override
      assert occurrence.decided_by == :override
      assert occurrence.title == "Special"
      assert occurrence.message == "Who is coming?"
      assert occurrence.applied_override_id == "ovr-1"
    end
  end

  describe "exception dormancy across schedule edits" do
    test "a suppression re-applies when the weekday moves onto its date" do
      sup = suppression("sup-1", @thursday_2025_10_02)

      wednesday = announcement(%{weekday: 3})

      assert [%{outcome: :post}] =
               Occurrences.window(
                 wednesday,
                 ~D[2025-10-01],
                 ~D[2025-10-07],
                 opts(suppressions: [sup])
               )

      thursday = announcement(%{weekday: 4})

      assert [%{outcome: :skipped_suppressed}] =
               Occurrences.window(
                 thursday,
                 ~D[2025-10-01],
                 ~D[2025-10-08],
                 opts(suppressions: [sup])
               )
    end

    test "an override re-applies when the weekday moves onto its date" do
      ovr = override("ovr-1", @thursday_2025_10_02, nil, "Special Thursday", nil)

      wednesday = announcement(%{weekday: 3})

      assert [%{outcome: :post, applied_override_id: nil}] =
               Occurrences.window(
                 wednesday,
                 ~D[2025-10-01],
                 ~D[2025-10-07],
                 opts(overrides: [ovr])
               )

      thursday = announcement(%{weekday: 4})

      assert [%{outcome: :post_override, title: "Special Thursday", applied_override_id: "ovr-1"}] =
               Occurrences.window(
                 thursday,
                 ~D[2025-10-01],
                 ~D[2025-10-08],
                 opts(overrides: [ovr])
               )
    end
  end

  describe "slot_collisions/4" do
    test "reports shared slots when two announcements would post together" do
      other = announcement(%{id: "ann-2"})

      assert [%{date: @thursday_2025_09_25, announcement_ids: ["ann-1", "ann-2"]}] =
               Occurrences.slot_collisions(
                 [%{announcement: announcement()}, %{announcement: other}],
                 @thursday_2025_09_25,
                 @thursday_2025_09_25,
                 opts()
               )
    end

    test "ignores different post times and suppressed occurrences" do
      other = announcement(%{id: "ann-2", post_time: ~T[20:00:00]})

      assert [] =
               Occurrences.slot_collisions(
                 [%{announcement: announcement()}, %{announcement: other}],
                 @thursday_2025_09_25,
                 @thursday_2025_09_25,
                 opts()
               )

      suppressed = %{
        announcement: announcement(%{id: "ann-2"}),
        suppressions: [suppression("sup-1", @thursday_2025_09_25)]
      }

      assert [] =
               Occurrences.slot_collisions(
                 [%{announcement: announcement()}, suppressed],
                 @thursday_2025_09_25,
                 @thursday_2025_09_25,
                 opts()
               )
    end
  end

  describe "warnings_for_schedule_change/6" do
    test "warns when a weekday edit changes intersecting exceptions" do
      sup = suppression("sup-1", @thursday_2025_10_02)

      assert [:exception_intersection_changed] =
               Occurrences.warnings_for_schedule_change(
                 announcement(%{weekday: 4}),
                 announcement(%{weekday: 3}),
                 [sup],
                 [],
                 ~D[2025-09-20],
                 ~D[2025-11-20],
                 opts()
               )
    end

    test "stays quiet when the same exceptions still intersect" do
      sup = suppression("sup-1", @thursday_2025_10_02)

      assert [] =
               Occurrences.warnings_for_schedule_change(
                 announcement(%{weekday: 4}),
                 announcement(%{post_time: ~T[20:00:00]}),
                 [sup],
                 [],
                 ~D[2025-09-20],
                 ~D[2025-11-20],
                 opts()
               )
    end
  end

  describe "resolve/3" do
    test "returns nil for a date with no scheduled occurrence" do
      assert Occurrences.resolve(announcement(), ~D[2025-09-26], opts()) == nil
    end

    test "resolves a single occurrence with its outcome" do
      assert %{date: @thursday_2025_09_25, outcome: :post} =
               Occurrences.resolve(announcement(), @thursday_2025_09_25, opts())
    end
  end
end
