defmodule Dhc.BeginnersWorkshops.DestinationTest do
  @moduledoc """
  ALE-441: manual destinations on Beginners' Workshops through
  `Dhc.BeginnersWorkshops.execute/3` with fixed clocks — saved on schedule and
  reschedule, and changed on their own by `update_destination`, which is never
  a reschedule.

  The contacted workshop (`contacted_fixture/3`) is Saturday 14 November 2026
  at 18:30 Dublin, Payment Cutoff Wednesday 11 November 18:30 UTC, Batch 1
  sent at 10:00 on 20 October with a window to 27 October 23:59.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakePage
  }

  alias Dhc.Email.Worker
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @now ~U[2026-10-22 12:00:00.000000Z]

  @destination %{
    "destination_name" => "National Basketball Arena",
    "destination_address" => "Tymon Park, Dublin 6w",
    "directions_url" => "https://maps.app.goo.gl/AbCdEf"
  }

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp run(actor, command, at \\ @now),
    do: BeginnersWorkshops.execute({:staff, actor}, command, clock: Clock.fixed(at))

  defp update_destination(actor, workshop, attrs, at \\ @now),
    do:
      run(
        actor,
        {:update_destination, workshop.id, Map.put_new(attrs, "venue", workshop.venue)},
        at
      )

  defp reschedule(actor, workshop, attrs) do
    attrs =
      Map.merge(
        %{
          "start_time" => Calendar.strftime(workshop.start_time, "%H:%M"),
          "end_time" => Calendar.strftime(workshop.end_time, "%H:%M")
        },
        attrs
      )

    run(actor, {:reschedule_workshop, workshop.id, attrs})
  end

  defp stored(workshop), do: Repo.get!(BeginnersWorkshop, workshop.id)

  defp destination(workshop) do
    workshop
    |> stored()
    |> Map.take([:destination_name, :destination_address, :directions_url])
  end

  defp email_logs(workshop) do
    Repo.all(
      from(l in IntakeEmailLog,
        join: i in Intake,
        on: i.id == l.intake_id,
        where: i.workshop_id == ^workshop.id,
        select: {l.intake_id, l.email_type, l.occasion}
      )
    )
  end

  defp notifications, do: Repo.all(from(n in Notification, select: n.notification_key))

  describe "schedule_workshop" do
    test "each date owns the shared destination, and label-only workshops stay valid", %{
      coordinator: coordinator
    } do
      assert {:ok, [first, second, label_only]} =
               run(
                 coordinator,
                 {:schedule_workshop,
                  [
                    workshop_attrs(Map.merge(@destination, %{"date" => "2026-11-14"})),
                    workshop_attrs(Map.merge(@destination, %{"date" => "2026-11-21"})),
                    workshop_attrs(%{"date" => "2026-11-28"})
                  ]},
                 now()
               )

      for view <- [first, second] do
        assert view.venue == "St. Andrew's Hall"
        assert view.destination_name == "National Basketball Arena"
        assert view.destination_address == "Tymon Park, Dublin 6w"
        assert view.directions_url == "https://maps.app.goo.gl/AbCdEf"
      end

      assert %{destination_name: nil, destination_address: nil, directions_url: nil} =
               label_only

      # Each workshop owns its saved copy: changing one leaves the other.
      assert {:ok, _} =
               update_destination(coordinator, stored(first), %{
                 "destination_address" => "Tymon Road, Dublin 6w"
               })

      assert destination(second).destination_address == "Tymon Park, Dublin 6w"
    end

    test "blank destination text is absent and the venue keeps its email-sized limit", %{
      coordinator: coordinator
    } do
      view =
        scheduled_fixture(coordinator, %{
          "destination_name" => "   ",
          "destination_address" => "",
          "directions_url" => ""
        })

      assert %{destination_name: nil, destination_address: nil, directions_url: nil} = view

      assert {:error, {:workshop, 0, %Ecto.Changeset{} = changeset}} =
               run(
                 coordinator,
                 {:schedule_workshop,
                  [
                    workshop_attrs(%{
                      "venue" => String.duplicate("v", 81),
                      "destination_name" => String.duplicate("n", 256),
                      "directions_url" => "javascript:alert(1)"
                    })
                  ]},
                 now()
               )

      assert %{venue: [_], destination_name: [_], directions_url: [message]} =
               errors_on(changeset)

      assert message == "Directions link must be an https link"
    end
  end

  describe "update_destination" do
    test "changes only the destination: no reschedule, email, Staff Notification or policy change",
         %{coordinator: coordinator} do
      {workshop, intakes} = contacted_fixture(coordinator, 2)
      coach = staff_fixture("coach")
      set_staff!(workshop.id, coach, [], actor: coordinator, clock: Clock.fixed(@now))

      before = stored(workshop)
      batches = Repo.all(from(b in Batch, where: b.workshop_id == ^workshop.id))
      logs = email_logs(workshop)
      jobs = all_enqueued(worker: Worker)
      keys = notifications()
      {:ok, console} = BeginnersWorkshops.workshop_console(workshop.id, clock: Clock.fixed(@now))

      assert {:ok, view} = update_destination(coordinator, workshop, @destination)

      assert view.destination_name == "National Basketball Arena"
      assert view.destination_address == "Tymon Park, Dublin 6w"
      assert view.directions_url == "https://maps.app.goo.gl/AbCdEf"

      after_update = stored(workshop)

      unchanged =
        ~w(venue date start_time end_time payment_cutoff contact_from payment_window_days
           capacity fee_cents reschedule_count status batches_paused)a

      assert Map.take(after_update, unchanged) == Map.take(before, unchanged)

      assert view.seats == console.workshop.seats
      assert view.stage == console.workshop.stage
      assert Repo.all(from(b in Batch, where: b.workshop_id == ^workshop.id)) == batches
      assert email_logs(workshop) == logs
      assert all_enqueued(worker: Worker) == jobs
      assert notifications() == keys

      for {intake, _token} <- intakes,
          do: assert(Repo.reload!(intake).state == intake.state)
    end

    test "omission keeps, explicit nil clears, and a new value replaces", %{
      coordinator: coordinator
    } do
      workshop = scheduled_fixture(coordinator, @destination)

      assert {:ok, _} =
               update_destination(coordinator, workshop, %{
                 "destination_address" => "Tymon Road, Dublin 6w"
               })

      assert destination(workshop) == %{
               destination_name: "National Basketball Arena",
               destination_address: "Tymon Road, Dublin 6w",
               directions_url: "https://maps.app.goo.gl/AbCdEf"
             }

      assert {:ok, view} =
               update_destination(coordinator, workshop, %{
                 "directions_url" => nil,
                 "destination_name" => ""
               })

      assert %{destination_name: nil, directions_url: nil} = view
      assert destination(workshop).destination_address == "Tymon Road, Dublin 6w"

      # Settings and an unrelated reschedule keep the saved destination.
      assert {:ok, _} = run(coordinator, {:update_workshop, workshop.id, %{"capacity" => 20}})

      assert {:ok, _} = reschedule(coordinator, workshop, %{"date" => "2026-11-21"})
      assert destination(workshop).destination_address == "Tymon Road, Dublin 6w"
    end

    test "an unchanged destination writes nothing", %{coordinator: coordinator} do
      workshop = scheduled_fixture(coordinator, @destination)
      before = stored(workshop)

      assert {:ok, _} = update_destination(coordinator, workshop, @destination)
      assert stored(workshop).updated_at == before.updated_at
    end

    test "a Maps link is validated and every field error is named", %{coordinator: coordinator} do
      workshop = scheduled_fixture(coordinator)

      for {url, message} <- [
            {"http://www.google.com/maps?q=Tallaght", "Directions link must be an https link"},
            {"https://evil.example.com/maps", "Directions link must be a Google Maps link"},
            {"https://user:pass@www.google.com/maps",
             "Directions link must not include a username or password"}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 update_destination(coordinator, workshop, %{"directions_url" => url})

        assert %{directions_url: [^message]} = errors_on(changeset)
      end

      assert {:error, %Ecto.Changeset{} = changeset} =
               update_destination(coordinator, workshop, %{
                 "destination_address" => String.duplicate("a", 501)
               })

      assert %{destination_address: [_]} = errors_on(changeset)
      assert destination(workshop).directions_url == nil
    end

    test "names the venue it describes", %{coordinator: coordinator} do
      workshop = scheduled_fixture(coordinator)

      assert {:error, :venue_changed} =
               update_destination(coordinator, workshop, Map.put(@destination, "venue", "Other"))

      assert {:error, %Ecto.Changeset{} = changeset} =
               run(coordinator, {:update_destination, workshop.id, @destination})

      assert %{venue: ["can't be blank"]} = errors_on(changeset)
      # Surrounding whitespace is not a different venue.
      assert {:ok, _} =
               update_destination(
                 coordinator,
                 workshop,
                 Map.put(@destination, "venue", "  #{workshop.venue} ")
               )
    end

    test "is refused once cancelled or finalised, and for anyone without manage", %{
      coordinator: coordinator
    } do
      workshop = scheduled_fixture(coordinator)

      assert {:error, :forbidden} =
               update_destination(staff_fixture("coach"), workshop, @destination)

      assert {:error, :not_found} =
               run(coordinator, {:update_destination, Ecto.UUID.generate(), @destination})

      force_status!(workshop.id, "cancelled")

      assert {:error, :already_cancelled} =
               update_destination(coordinator, workshop, @destination)

      force_status!(workshop.id, "finalised")

      assert {:error, :after_finalisation} =
               update_destination(coordinator, workshop, @destination)
    end
  end

  describe "reschedule_workshop" do
    test "saves a destination with a genuine move and still emails the open places", %{
      coordinator: coordinator
    } do
      {workshop, _intakes} = contacted_fixture(coordinator, 1)

      assert {:ok, view} =
               reschedule(
                 coordinator,
                 workshop,
                 Map.merge(@destination, %{"venue" => "The Hub"})
               )

      assert view.venue == "The Hub"
      assert view.destination_name == "National Basketball Arena"
      assert stored(workshop).reschedule_count == 1

      assert [{_, "rescheduled", "rescheduled:1"}] =
               Enum.filter(email_logs(workshop), &(elem(&1, 1) == "rescheduled"))
    end

    test "a destination alone is not a move", %{coordinator: coordinator} do
      workshop = scheduled_fixture(coordinator)

      assert {:error, %Ecto.Changeset{} = changeset} =
               reschedule(coordinator, workshop, @destination)

      assert %{date: [_]} = errors_on(changeset)
      assert destination(workshop).destination_name == nil
      assert stored(workshop).reschedule_count == 0
    end
  end

  describe "the Intake page" do
    test "carries the destination beside the label, and legacy rows carry none", %{
      coordinator: coordinator
    } do
      {workshop, [{_intake, token}]} = contacted_fixture(coordinator, 1)

      assert {:ok, %{workshop: page}} = IntakePage.show(token, Clock.fixed(@now))
      assert %{venue: "St. Andrew's Hall", destination_name: nil, directions_url: nil} = page

      assert {:ok, _} = update_destination(coordinator, workshop, @destination)

      assert {:ok, %{workshop: page}} = IntakePage.show(token, Clock.fixed(@now))

      assert %{
               venue: "St. Andrew's Hall",
               destination_name: "National Basketball Arena",
               destination_address: "Tymon Park, Dublin 6w",
               directions_url: "https://maps.app.goo.gl/AbCdEf"
             } = page
    end

    test "an inactive page carries no workshop at all", %{coordinator: coordinator} do
      {workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      assert {:ok, _} = update_destination(coordinator, workshop, @destination)
      force_intake_state!(intake.id, "lapsed")

      assert {:ok, %{closed_reason: :inactive, workshop: nil}} =
               IntakePage.show(token, Clock.fixed(@now))
    end
  end
end
