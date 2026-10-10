defmodule Dhc.BeginnersWorkshops.BatchesTest do
  @moduledoc """
  ALE-380: automatic Batches through `Dhc.BeginnersWorkshops.execute/3` with
  a fixed clock — `send_due_batch` timing, sizing, the Intakes and contact
  emails it creates, the coordinator alerts, pausing, the fee lock, and the
  stages the Batch facts now drive end to end.

  The workshop under test (unless a test says otherwise): Saturday 14
  November 2026 at 18:30 Dublin, Payment Cutoff Wednesday 11 November 18:30
  (GMT, so 18:30 UTC), contact from Tuesday 20 October, a 7-day window and 3
  seats. Dublin is on IST (UTC+1) until Sunday 25 October, so 10:00 Dublin
  is 09:00 UTC on the 20th and 10:00 UTC from the 26th.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures
  import Swoosh.TestAssertions

  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeLink
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.Template
  alias Dhc.Email.Worker
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @batch_1_at ~U[2026-10-20 09:00:00.000000Z]
  # Batch 1's window ends 27 October 23:59 Dublin (GMT by then).
  @batch_1_window_end ~U[2026-10-27 23:59:59.999999Z]
  @batch_2_at ~U[2026-10-28 10:00:00.000000Z]

  setup do
    coordinator = staff_fixture("beginners_coordinator")

    workshop =
      scheduled_fixture(coordinator, %{"contact_from" => "2026-10-20", "capacity" => 3})

    %{coordinator: coordinator, workshop: workshop}
  end

  defp send_due(workshop, now),
    do:
      BeginnersWorkshops.execute(:system, {:send_due_batch, workshop.id}, clock: Clock.fixed(now))

  defp staff(command, staff, workshop, now \\ @batch_1_at),
    do:
      BeginnersWorkshops.execute({:staff, staff}, {command, workshop.id}, clock: Clock.fixed(now))

  defp batches(workshop),
    do: Repo.all(from(b in Batch, where: b.workshop_id == ^workshop.id, order_by: b.number))

  defp intakes(workshop),
    do:
      Repo.all(
        from(i in Intake, where: i.workshop_id == ^workshop.id, order_by: [i.queue_date, i.id])
      )

  defp contact_jobs, do: all_enqueued(worker: Worker)

  defp notifications(principal_id),
    do:
      Repo.all(
        from(n in Notification, where: n.principal_id == ^principal_id, order_by: n.created_at)
      )

  defp stage(workshop, now) do
    %{upcoming: rows} = BeginnersWorkshops.list_workshops(clock: Clock.fixed(now))
    Enum.find(rows, &(&1.id == workshop.id)).stage
  end

  describe "Batch 1 timing" do
    test "nothing is sent before 10:00 on the contact-from date; Batch 1 goes at 10:00",
         %{workshop: w} do
      waiting_people_fixture(5)

      for now <- [~U[2026-10-19 12:00:00Z], ~U[2026-10-20 08:59:59Z]] do
        assert {:ok, %{outcome: :not_due}} = send_due(w, now)
      end

      assert batches(w) == []
      assert contact_jobs() == []

      assert {:ok, %{outcome: :sent, batch: batch}} = send_due(w, @batch_1_at)

      assert %{number: 1, size: 3, sent_at: @batch_1_at, window_ends_at: @batch_1_window_end} =
               batch
    end

    test "the Batch is the live proposal: waiting people in priority order, skipping open Intakes and anyone not waiting",
         %{workshop: w, coordinator: coordinator} do
      [first, second, third, fourth] = waiting_people_fixture(4)
      _removed = waiting_person_fixture(~U[2024-01-01 00:00:00Z], status: "removed")
      _attended = waiting_person_fixture(~U[2024-01-02 00:00:00Z], status: "attended")

      # `first` already has an open Intake in another workshop.
      other = scheduled_fixture(coordinator, %{"contact_from" => "2026-10-20", "capacity" => 1})
      assert {:ok, %{outcome: :sent}} = send_due(other, @batch_1_at)
      assert [%Intake{waitlist_id: first_id}] = intakes(other)
      assert first_id == first.id

      assert {:ok, %{outcome: :sent, batch: %{size: 3}}} = send_due(w, @batch_1_at)

      assert Enum.map(intakes(w), & &1.waitlist_id) == [second.id, third.id, fourth.id]
    end

    test "each Intake is contacted, records its Batch and queue date, and has a link whose hash alone is stored",
         %{workshop: w} do
      [person | _] = waiting_people_fixture(3)

      assert {:ok, %{outcome: :sent, batch: %{id: batch_id}}} = send_due(w, @batch_1_at)

      assert [intake | _] = intakes(w)

      assert %Intake{
               state: "contacted",
               origin: "batch",
               batch_id: ^batch_id,
               link_generation: 1,
               contacted_at: @batch_1_at
             } = intake

      assert intake.waitlist_id == person.id
      assert intake.queue_date == person.initial_registration_date

      token = IntakeLink.token(intake.id, 1)
      assert intake.link_token_hash == IntakeLink.hash(token)
      refute intake.link_token_hash == token
      assert Enum.uniq_by(intakes(w), & &1.link_token_hash) |> length() == 3
    end

    test "a person's Waitlist standing stays waiting while their Intake is open", %{workshop: w} do
      people = waiting_people_fixture(3)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      for person <- people,
          do: assert(Repo.get!(Dhc.Waitlist.WaitlistEntry, person.id).status == "waiting")
    end
  end

  describe "the contact email" do
    test "each new Intake queues Contact – pay with its own link and writes an Intake Email log row",
         %{workshop: w} do
      [person] = [waiting_person_fixture(~U[2025-01-01 12:00:00Z], first_name: "Aoife")]

      assert {:ok, %{outcome: :sent, batch: %{size: 1}}} = send_due(w, @batch_1_at)
      assert [intake] = intakes(w)

      assert [%{args: args}] = contact_jobs()

      assert %{
               "email" => email,
               "transactional_id" => "beginnersWorkshopAction",
               "data_variables" => %{
                 "MESSAGE_HTML" => html,
                 "BUTTON_LABEL" => "Pay for your place"
               }
             } = args

      assert email == person.email
      assert html =~ "Aoife"
      refute Jason.encode!(args) =~ IntakeLink.token(intake.id, 1)

      assert :ok = perform_job(Worker, args)

      url = IntakeLink.url(IntakeLink.token(intake.id, 1))
      assert url =~ "/beginners/intake/"

      assert_email_sent(fn sent ->
        assert sent.provider_options.template.variables["BUTTON_URL"] == url
      end)

      assert [
               %IntakeEmailLog{
                 email_type: "contact_pay",
                 occasion: "contact",
                 queued_at: @batch_1_at
               }
             ] = Repo.all(from(l in IntakeEmailLog, where: l.intake_id == ^intake.id))
    end

    test "the email states the window end and the Payment Cutoff", %{workshop: w} do
      Repo.update_all(Template |> where(email_type: "contact_pay"),
        set: [
          body: %{
            "type" => "doc",
            "content" => [
              %{
                "type" => "paragraph",
                "content" => [
                  %{"type" => "placeholder", "attrs" => %{"name" => "windowEnd"}},
                  %{"type" => "text", "text" => " / "},
                  %{"type" => "placeholder", "attrs" => %{"name" => "paymentCutoff"}}
                ]
              }
            ]
          }
        ]
      )

      waiting_people_fixture(1)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      assert [%{args: %{"data_variables" => %{"MESSAGE_HTML" => html}}}] = contact_jobs()

      assert html ==
               "<p>Tuesday 27 October 2026, 23:59 / Wednesday 11 November 2026, 18:30</p>"
    end

    test "a rolled-back pass sends nothing", %{workshop: w, coordinator: coordinator} do
      waiting_people_fixture(3)

      # A template the contact email can't fill makes the pass fail mid-Batch.
      Repo.update_all(Template |> where(email_type: "contact_pay"),
        set: [
          body: %{
            "type" => "doc",
            "content" => [
              %{
                "type" => "paragraph",
                "content" => [%{"type" => "placeholder", "attrs" => %{"name" => "refundAmount"}}]
              }
            ]
          }
        ]
      )

      assert {:error, _reason} = send_due(w, @batch_1_at)

      assert batches(w) == []
      assert intakes(w) == []
      assert contact_jobs() == []
      assert Repo.all(IntakeEmailLog) == []
      assert notifications(coordinator) == []
    end
  end

  describe "later Batches" do
    test "the next Batch goes the morning after the previous window ends, sized capacity − paid",
         %{workshop: w} do
      waiting_people_fixture(6)
      assert {:ok, %{outcome: :sent, batch: %{size: 3}}} = send_due(w, @batch_1_at)

      [paid | _] = intakes(w)
      force_intake_state!(paid.id, "paid")

      for now <- [
            ~U[2026-10-22 12:00:00Z],
            # 23:59 Dublin on the last day of the window, and the morning after.
            ~U[2026-10-27 23:59:30Z],
            ~U[2026-10-28 09:59:59Z]
          ] do
        assert {:ok, %{outcome: :not_due}} = send_due(w, now)
      end

      assert {:ok, %{outcome: :sent, batch: batch}} = send_due(w, @batch_2_at)
      # 3 seats − 1 paid; the 2 still contacted from Batch 1 are skipped.
      assert %{number: 2, size: 2, window_ends_at: ~U[2026-11-04 23:59:59.999999Z]} = batch
      assert Enum.count(intakes(w)) == 5
    end

    test "a new window length applies to later Batches only", %{workshop: w, coordinator: c} do
      waiting_people_fixture(6)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      assert {:ok, _} =
               BeginnersWorkshops.execute(
                 {:staff, c},
                 {:update_workshop, w.id, %{"payment_window_days" => 2}},
                 clock: Clock.fixed(@batch_1_at)
               )

      assert [%{window_ends_at: @batch_1_window_end}] = batches(w)

      assert {:ok, %{batch: %{window_ends_at: ~U[2026-10-30 23:59:59.999999Z]}}} =
               send_due(w, @batch_2_at)
    end
  end

  describe "pausing" do
    test "nothing is sent while paused; a due Batch goes out after a resume",
         %{workshop: w, coordinator: coordinator} do
      waiting_people_fixture(3)

      assert {:ok, %{stage: :batches_paused}} =
               staff(:pause_batches, coordinator, w, ~U[2026-10-19 12:00:00Z])

      assert {:ok, %{outcome: :not_due}} = send_due(w, @batch_1_at)
      assert stage(w, @batch_1_at) == :batches_paused

      assert {:ok, %{stage: :next_batch_due}} =
               staff(:resume_batches, coordinator, w, ~U[2026-10-20 15:00:00Z])

      assert {:ok, %{outcome: :sent, batch: %{sent_at: ~U[2026-10-20 15:00:00.000000Z]}}} =
               send_due(w, ~U[2026-10-20 15:00:00Z])
    end

    test "pausing stops new Batches only: an open window and contacted people are untouched",
         %{workshop: w, coordinator: coordinator} do
      waiting_people_fixture(6)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      assert {:ok, _} = staff(:pause_batches, coordinator, w, ~U[2026-10-21 12:00:00Z])

      assert Enum.all?(intakes(w), &(&1.state == "contacted"))
      assert [%{window_ends_at: @batch_1_window_end}] = batches(w)
      assert {:ok, %{outcome: :not_due}} = send_due(w, @batch_2_at)
    end

    test "pause and resume are idempotent and record who and when",
         %{workshop: w, coordinator: coordinator} do
      officer = staff_fixture("president")
      paused_at = ~U[2026-10-19 12:00:00.000000Z]

      assert {:ok, _} = staff(:pause_batches, coordinator, w, paused_at)
      assert {:ok, _} = staff(:pause_batches, officer, w, ~U[2026-10-19 13:00:00Z])

      assert %BeginnersWorkshop{
               batches_paused: true,
               batches_paused_at: ^paused_at,
               batches_paused_by_principal_id: ^coordinator
             } = Repo.get!(BeginnersWorkshop, w.id)

      resumed_at = ~U[2026-10-19 14:00:00.000000Z]
      assert {:ok, _} = staff(:resume_batches, officer, w, resumed_at)
      assert {:ok, _} = staff(:resume_batches, coordinator, w, ~U[2026-10-19 15:00:00Z])

      assert %BeginnersWorkshop{
               batches_paused: false,
               batches_resumed_at: ^resumed_at,
               batches_resumed_by_principal_id: ^officer
             } = Repo.get!(BeginnersWorkshop, w.id)
    end

    test "is allowed only while the workshop is scheduled, and only for managers",
         %{workshop: w, coordinator: coordinator} do
      assert {:error, :forbidden} = staff(:pause_batches, staff_fixture("coach"), w)
      assert {:error, :forbidden} = staff(:resume_batches, staff_fixture("member"), w)

      assert {:error, :not_found} =
               staff(:pause_batches, coordinator, %{id: Ecto.UUID.generate()})

      force_status!(w.id, "finalised")
      assert {:error, :after_finalisation} = staff(:pause_batches, coordinator, w)

      other = scheduled_fixture(coordinator)
      force_status!(other.id, "cancelled")
      assert {:error, :already_cancelled} = staff(:resume_batches, coordinator, other)
    end
  end

  describe "seats" do
    test "with no free seats nothing is sent, and a Batch goes as soon as a seat frees",
         %{workshop: w} do
      waiting_people_fixture(5)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)
      for intake <- intakes(w), do: force_intake_state!(intake.id, "paid")

      assert {:ok, %{outcome: :not_due}} = send_due(w, @batch_2_at)
      assert stage(w, @batch_2_at) == :full

      [leaving | _] = intakes(w)
      force_intake_state!(leaving.id, "deferred")

      freed_at = ~U[2026-10-29 15:30:00Z]
      assert {:ok, %{outcome: :sent, batch: %{number: 2, size: 1}}} = send_due(w, freed_at)
    end

    test "the nobody-waiting Notification is sent only once, and nothing else happens",
         %{workshop: w, coordinator: coordinator} do
      officer = staff_fixture("president")

      assert {:ok, %{outcome: :nobody_waiting}} = send_due(w, @batch_1_at)
      assert {:ok, %{outcome: :nobody_waiting}} = send_due(w, ~U[2026-10-21 09:00:00Z])

      assert [%Notification{body: body, notification_key: key}] = notifications(coordinator)
      assert key == "beginners-workshop:#{w.id}:nobody-waiting"
      assert body =~ "nobody is left waiting"
      assert notifications(officer) == []

      assert batches(w) == []
      assert contact_jobs() == []
    end

    test "Batch sent goes to the coordinator-alert holders only, with its number and size",
         %{workshop: w, coordinator: coordinator} do
      officer = staff_fixture("president")
      waiting_people_fixture(2)

      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      assert [%Notification{body: body, notification_key: key}] = notifications(coordinator)
      assert key == "beginners-workshop:#{w.id}:batch:1"
      assert body =~ "Batch 1 sent"
      assert body =~ "2 people contacted"
      assert notifications(officer) == []
    end
  end

  describe "the Payment Cutoff" do
    test "nothing is sent at or after the cutoff", %{coordinator: coordinator} do
      waiting_people_fixture(3)

      w =
        scheduled_fixture(coordinator, %{
          "contact_from" => "2026-11-11",
          "payment_cutoff_time" => "18:30"
        })

      assert {:ok, %{outcome: :not_due}} = send_due(w, ~U[2026-11-11 18:30:00Z])
      assert {:ok, %{outcome: :not_due}} = send_due(w, ~U[2026-11-12 10:00:00Z])
      assert batches(w) == []

      assert {:ok, %{outcome: :sent}} = send_due(w, ~U[2026-11-11 18:29:00Z])
    end

    test "a window reaching the cutoff date ends at the cutoff itself", %{coordinator: c} do
      waiting_people_fixture(9)

      for {contact_from, window_end} <- [
            {"2026-11-03", ~U[2026-11-10 23:59:59.999999Z]},
            {"2026-11-04", ~U[2026-11-11 18:30:00.000000Z]},
            {"2026-11-06", ~U[2026-11-11 18:30:00.000000Z]}
          ] do
        w = scheduled_fixture(c, %{"contact_from" => contact_from, "capacity" => 1})
        {:ok, date} = Date.from_iso8601(contact_from)
        now = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")

        assert {:ok, %{outcome: :sent, batch: %{window_ends_at: ^window_end}}} =
                 send_due(w, now)
      end
    end

    test "after a window that ended at the cutoff there is no further Batch", %{coordinator: c} do
      waiting_people_fixture(6)
      w = scheduled_fixture(c, %{"contact_from" => "2026-11-06", "capacity" => 3})

      assert {:ok, %{outcome: :sent}} = send_due(w, ~U[2026-11-06 10:00:00Z])
      assert {:ok, %{outcome: :not_due}} = send_due(w, ~U[2026-11-12 10:00:00Z])
      assert Enum.count(batches(w)) == 1
    end
  end

  describe "exactly-once" do
    test "running the pass twice sends one Batch", %{workshop: w, coordinator: coordinator} do
      waiting_people_fixture(5)

      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)
      assert {:ok, %{outcome: :not_due}} = send_due(w, @batch_1_at)

      assert Enum.count(batches(w)) == 1
      assert Enum.count(intakes(w)) == 3
      assert Enum.count(contact_jobs()) == 3
      assert Repo.aggregate(IntakeEmailLog, :count) == 3
      assert Enum.count(notifications(coordinator)) == 1
    end

    test "the sweep runs every due pass through the boundary", %{workshop: w} do
      waiting_people_fixture(3)
      clock = Clock.fixed(@batch_1_at)

      assert %{sent: 1, failed: 0} = BeginnersWorkshops.run_due_passes(clock: clock)
      assert %{sent: 0, not_due: 1} = BeginnersWorkshops.run_due_passes(clock: clock)
      assert Enum.count(batches(w)) == 1
    end
  end

  describe "authorization" do
    test "only the system actor may send a Batch", %{workshop: w, coordinator: coordinator} do
      waiting_people_fixture(3)

      for actor <- [{:staff, coordinator}, :stripe, {:intake_link, "token"}] do
        assert {:error, :forbidden} =
                 BeginnersWorkshops.execute(actor, {:send_due_batch, w.id},
                   clock: Clock.fixed(@batch_1_at)
                 )
      end

      assert batches(w) == []
      assert {:error, :not_found} = send_due(%{id: Ecto.UUID.generate()}, @batch_1_at)
    end
  end

  describe "update_workshop once Intakes exist" do
    setup %{workshop: w} do
      waiting_people_fixture(3)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)
      :ok
    end

    defp update_settings(staff, w, attrs),
      do:
        BeginnersWorkshops.execute({:staff, staff}, {:update_workshop, w.id, attrs},
          clock: Clock.fixed(@batch_1_at)
        )

    test "refuses a fee change (:fee_locked)", %{workshop: w, coordinator: c} do
      assert {:error, :fee_locked} = update_settings(c, w, %{"fee_cents" => 4500})
      assert Repo.get!(BeginnersWorkshop, w.id).fee_cents == 4000
      # The same fee is not a change.
      assert {:ok, %{fee_cents: 4000}} = update_settings(c, w, %{"fee_cents" => 4000})
    end

    test "an earlier Payment Cutoff clamps the open Batch window to it, as reschedule does",
         %{workshop: w, coordinator: c} do
      assert {:ok, %{payment_cutoff: ~U[2026-10-25 12:00:00.000000Z]}} =
               update_settings(c, w, %{
                 "payment_cutoff_date" => "2026-10-25",
                 "payment_cutoff_time" => "12:00"
               })

      assert [%Batch{window_ends_at: ~U[2026-10-25 12:00:00.000000Z]}] =
               Repo.all(from(b in Batch, where: b.workshop_id == ^w.id))
    end

    test "refuses a contact-from change once Batch 1 has gone out", %{workshop: w, coordinator: c} do
      assert {:error, :contact_from_locked} =
               update_settings(c, w, %{"contact_from" => "2026-10-25"})

      assert {:ok, %{capacity: 5, contact_from_editable: false}} =
               update_settings(c, w, %{"capacity" => 5})
    end
  end

  describe "stages driven by the Batch facts" do
    test "window_open, next_batch_due, batches_paused and full end to end",
         %{workshop: w, coordinator: coordinator} do
      waiting_people_fixture(6)
      assert stage(w, ~U[2026-10-20 08:00:00Z]) == :before_contact_from
      assert stage(w, @batch_1_at) == :next_batch_due

      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)
      assert stage(w, ~U[2026-10-21 12:00:00Z]) == :window_open
      assert stage(w, @batch_2_at) == :next_batch_due

      assert {:ok, _} = staff(:pause_batches, coordinator, w, @batch_2_at)
      assert stage(w, @batch_2_at) == :batches_paused
      assert {:ok, _} = staff(:resume_batches, coordinator, w, @batch_2_at)

      for intake <- intakes(w), do: force_intake_state!(intake.id, "paid")
      assert stage(w, @batch_2_at) == :full
    end
  end
end
