defmodule Dhc.BeginnersWorkshops.ReportTest do
  @moduledoc """
  ALE-397: the Dashboard tab's report figures. The rows are inserted in
  their final states (the report is a read model over them), so each figure
  can be checked against a hand count:

    * workshop A — finalised 14 November 2026, inside the 12 months: one
      Batch and two fast-tracks, every exit kind, a corrected no-show and an
      anonymised attendee who had joined;
    * workshop B — cancelled 21 November 2026: listed, no rates, outside
      every 12-month figure;
    * workshop C — finalised 1 October 2025, listed but outside the 12
      months.

  The report is read at 12:00 on 1 December 2026 (Dublin = UTC in winter).
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Batch, BeginnersWorkshop, CarriedFee, Intake, IntakeEvent, Report}
  alias Dhc.Waitlist.WaitlistEntry

  @read_at ~U[2026-12-01 12:00:00Z]
  # Batch 1 of workshop A: sent 20 October, window to 27 October 23:59 Dublin.
  @sent_at ~U[2026-10-20 09:00:00.000000Z]
  @window_end ~U[2026-10-27 23:59:59.999999Z]
  @in_window ~U[2026-10-25 12:00:00.000000Z]
  @after_window ~U[2026-10-30 12:00:00.000000Z]

  setup do
    coordinator = staff_fixture()

    a = scheduled_fixture(coordinator, %{"date" => "2026-11-14"})
    b = scheduled_fixture(coordinator, %{"date" => "2026-11-21"})
    c = scheduled_fixture(coordinator, %{"date" => "2026-11-28"})

    force_status!(a.id, "finalised")
    force_status!(b.id, "cancelled")
    force_status!(c.id, "finalised")

    Repo.get!(BeginnersWorkshop, c.id)
    |> Ecto.Changeset.change(date: ~D[2025-10-01])
    |> Repo.update!()

    batch =
      Repo.insert!(%Batch{
        workshop_id: a.id,
        number: 1,
        size: 7,
        sent_at: @sent_at,
        window_ends_at: @window_end
      })

    %{a: a, b: b, c: c, batch: batch}
  end

  defp person!(status, registered_at \\ ~U[2026-01-01 12:00:00Z], removed_at \\ nil) do
    Repo.insert!(%WaitlistEntry{
      email: "#{System.unique_integer([:positive])}@report.example.com",
      status: status,
      initial_registration_date: registered_at,
      last_status_change: registered_at,
      removed_at: removed_at
    })
  end

  # One Intake in its final state for a new person with `standing`.
  defp intake!(workshop, state, opts) do
    standing = Keyword.get(opts, :standing, "removed")
    queue_date = Keyword.get(opts, :queue_date, ~U[2026-01-01 12:00:00Z])

    entry =
      if Keyword.get(opts, :anonymised),
        do: nil,
        else: person!(standing, queue_date, if(standing == "removed", do: queue_date))

    batch = Keyword.get(opts, :batch)

    Repo.insert!(%Intake{
      workshop_id: workshop.id,
      waitlist_id: entry && entry.id,
      state: state,
      origin: if(batch, do: "batch", else: "fast_track"),
      batch_id: batch && batch.id,
      queue_date: queue_date,
      link_token_hash: :crypto.strong_rand_bytes(32),
      contacted_at: Keyword.get(opts, :contacted_at, @sent_at),
      paid_via: if(opts[:paid_at], do: "stripe"),
      paid_at: opts[:paid_at],
      anonymised_at: if(Keyword.get(opts, :anonymised), do: @sent_at),
      invitation_outcome: opts[:invitation_outcome]
    })
  end

  defp event!(intake, command, correction \\ nil) do
    Repo.insert!(%IntakeEvent{
      intake_id: intake.id,
      command: command,
      correction: correction,
      occurred_at: @after_window
    })
  end

  defp seed!(%{a: a, b: b, c: c, batch: batch}) do
    # Workshop A, Batch 1.
    intake!(a, "attended",
      batch: batch,
      paid_at: @in_window,
      standing: "joined",
      queue_date: ~U[2025-11-14 12:00:00Z]
    )

    intake!(a, "attended",
      batch: batch,
      paid_at: @after_window,
      standing: "invited",
      queue_date: ~U[2026-05-14 12:00:00Z]
    )

    intake!(a, "no_show", batch: batch, paid_at: @in_window)
    intake!(a, "declined", batch: batch)
    intake!(a, "lapsed", batch: batch)
    intake!(a, "deferred", batch: batch, paid_at: @in_window)

    a
    |> intake!("deferred", batch: batch, paid_at: @in_window)
    |> event!("correct_attendance", "deferred")

    # Workshop A, fast-tracks: an anonymised attendee who had joined, and an
    # attendee still Invitable.
    intake!(a, "attended",
      paid_at: @in_window,
      anonymised: true,
      invitation_outcome: "joined"
    )

    intake!(a, "attended", paid_at: @in_window, standing: "attended")

    # Workshop B (cancelled): its paid person deferred, its contacted one
    # returned, both by the cancellation.
    b |> intake!("deferred", paid_at: @in_window) |> event!("cancel_workshop")
    b |> intake!("returned", []) |> event!("cancel_workshop")

    # Workshop C (outside the 12 months): one attendee who joined.
    {:ok, c_batch} =
      Repo.insert(%Batch{
        workshop_id: c.id,
        number: 1,
        size: 1,
        sent_at: ~U[2025-09-01 09:00:00.000000Z],
        window_ends_at: ~U[2025-09-08 22:59:59.999999Z]
      })

    intake!(c, "attended",
      batch: c_batch,
      paid_at: ~U[2025-09-02 12:00:00.000000Z],
      standing: "joined",
      queue_date: ~U[2024-10-01 12:00:00Z]
    )

    :ok
  end

  defp report, do: BeginnersWorkshops.report(clock: clock(@read_at))

  defp row(report, workshop), do: Enum.find(report.outcomes, &(&1.workshop_id == workshop.id))

  describe "outcomes" do
    setup ctx do
      seed!(ctx)
    end

    test "lists past and cancelled workshops, newest first", ctx do
      assert Enum.map(report().outcomes, &{&1.workshop_id, &1.status}) == [
               {ctx.b.id, "cancelled"},
               {ctx.a.id, "finalised"},
               {ctx.c.id, "finalised"}
             ]
    end

    test "counts every stage, anonymised Intakes included, with rates out of who could take it",
         ctx do
      row = row(report(), ctx.a)

      assert row.batches_sent == 1
      assert row.contacted == %{total: 9, batch: 7, fast_track: 2}

      assert row.exits_before_paying == %{
               declined: 1,
               lapsed: 1,
               returned: 0,
               withdrawn: 0,
               total: 2,
               rate: 2 / 9
             }

      assert row.paid == %{total: 7, carried_fee: 0}

      # The no-show corrected to deferred was seated at finalisation, so it
      # is a no-show here, not an exit after paying.
      assert row.exits_after_paying == %{
               deferred: 1,
               cancelled_refunded: 0,
               withdrawn: 0,
               total: 1,
               rate: 1 / 7
             }

      assert row.attendance == %{seated: 6, attended: 4, no_show: 2, rate: 4 / 6}

      # The anonymised attendee's recorded outcome counts as joined.
      assert row.after_attending == %{invitable: 1, invited_not_joined: 1, joined: 2}
      assert row.conversion_rate == 0.5
    end

    test "expands into its Batches and fast-tracks", ctx do
      assert [batch, fast_tracks] = row(report(), ctx.a).groups

      assert batch == %{
               kind: :batch,
               number: 1,
               window_ends_at: @window_end,
               contacted: 7,
               paid_in_window: 4,
               paid_later: 1,
               declined: 1,
               unpaid_at_cutoff: 1
             }

      assert fast_tracks == %{
               kind: :fast_track,
               number: nil,
               window_ends_at: nil,
               contacted: 2,
               paid_in_window: 2,
               paid_later: 0,
               declined: 0,
               unpaid_at_cutoff: 0
             }
    end

    test "a cancelled workshop keeps its counts but has no rates", ctx do
      row = row(report(), ctx.b)

      assert row.contacted.total == 2
      assert row.exits_after_paying.deferred == 1
      assert row.exits_before_paying.returned == 1
      assert row.exits_before_paying.rate == nil
      assert row.exits_after_paying.rate == nil
      assert row.attendance.rate == nil
      assert row.conversion_rate == nil

      # Returned by the cancellation, not left unpaid at the cutoff.
      assert [%{kind: :fast_track, unpaid_at_cutoff: 0}] = row.groups
    end
  end

  describe "the last 12 months" do
    setup ctx do
      seed!(ctx)
    end

    test "cover finalised workshops only, cancelled and older ones left out" do
      assert report().twelve_months == %{
               workshops: 1,
               attended: 4,
               joined: 2,
               invitable: 1,
               invited_not_joined: 1,
               average_attendees: 4.0,
               conversion_rate: 0.5
             }
    end

    test "time to a seat is the median over Batch attendees, queue date to workshop date" do
      # 365 and 184 days; the fast-tracks and workshop C do not count.
      assert report().queue.median_days_to_seat == 274.5
    end
  end

  describe "the queue" do
    test "waits, workshops to clear, retention, Invitable and outstanding Carried Fees", ctx do
      seed!(ctx)

      person!("waiting", ~U[2026-11-01 12:00:00Z])
      person!("waiting", ~U[2026-11-21 12:00:00Z])
      person!("waiting", ~U[2026-06-04 12:00:00Z])
      person!("removed", ~U[2026-01-01 12:00:00Z], ~U[2026-10-01 12:00:00Z])
      person!("removed", ~U[2026-01-01 12:00:00Z], ~U[2026-08-01 12:00:00Z])

      Repo.insert!(%CarriedFee{
        waitlist_id: person!("waiting", ~U[2026-11-30 12:00:00Z]).id,
        status: "held",
        origin: "import",
        imported_paid_text: "Yes",
        amount_cents: 3500,
        stripe_payment_intent_id: "pi_report",
        status_changed_at: @sent_at
      })

      Repo.insert!(%CarriedFee{
        waitlist_id: nil,
        status: "held",
        origin: "import",
        imported_paid_text: "paid",
        status_changed_at: @sent_at
      })

      Repo.insert!(%CarriedFee{
        waitlist_id: nil,
        status: "forfeited",
        origin: "import",
        imported_paid_text: "paid",
        amount_cents: 4000,
        status_changed_at: @sent_at
      })

      queue = report().queue

      # Waits of 30, 10, 180 and 1 days.
      assert queue.waiting == 4
      assert queue.median_wait_days == 20.0
      assert queue.longest_wait_days == 180
      # 4 waiting ÷ 4 attendees per workshop.
      assert queue.workshops_to_clear == 1
      # Removed on 1 October (within 3 months); 1 August is past retention.
      # The seeded Intakes' people were removed on their queue dates.
      assert queue.removed_in_retention == 1
      assert queue.invitable == 1
      assert queue.carried_fees == %{count: 2, total_paid_cents: 3500, unlinked: 1}
    end

    test "is empty without Intakes or people" do
      report = report()

      # Workshop A is in the 12 months but nobody attended: nothing to divide by.
      assert report.twelve_months.workshops == 1
      assert report.twelve_months.average_attendees == 0.0
      assert report.twelve_months.conversion_rate == nil

      assert %{
               queue: %{
                 waiting: 0,
                 median_wait_days: nil,
                 longest_wait_days: nil,
                 median_days_to_seat: nil,
                 workshops_to_clear: nil,
                 removed_in_retention: 0,
                 invitable: 0,
                 carried_fees: %{count: 0, total_paid_cents: 0, unlinked: 0}
               }
             } = report
    end
  end

  test "median" do
    assert Report.median([]) == nil
    assert Report.median([3, 1, 2]) == 2
    assert Report.median([4, 1, 3, 2]) == 2.5
  end
end
