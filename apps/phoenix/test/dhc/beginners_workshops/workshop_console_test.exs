defmodule Dhc.BeginnersWorkshops.WorkshopConsoleTest do
  @moduledoc """
  ALE-380: the console read model — the Next Batch preview (the live
  proposal, its size as capacity − paid, when it goes out or that Batches
  are paused), the roster groups, the Batches sent and the nobody-waiting
  attention item — read through `Dhc.BeginnersWorkshops.workshop_console/2`
  at a fixed clock. The preview must be exactly what `send_due_batch` would
  send at that moment.
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, Intake}
  alias Dhc.Repo

  @batch_1_at ~U[2026-10-20 09:00:00.000000Z]

  setup do
    coordinator = staff_fixture("beginners_coordinator")

    workshop =
      scheduled_fixture(coordinator, %{"contact_from" => "2026-10-20", "capacity" => 3})

    %{coordinator: coordinator, workshop: workshop}
  end

  defp console(workshop, now) do
    assert {:ok, console} =
             BeginnersWorkshops.workshop_console(workshop.id, clock: Clock.fixed(now))

    console
  end

  defp send_due(workshop, now),
    do:
      BeginnersWorkshops.execute(:system, {:send_due_batch, workshop.id}, clock: Clock.fixed(now))

  test "an unknown workshop is not found" do
    assert {:error, :not_found} = BeginnersWorkshops.workshop_console(Ecto.UUID.generate())
    assert {:error, :not_found} = BeginnersWorkshops.workshop_console("nope")
  end

  describe "the Next Batch preview" do
    test "before the contact-from date: the live proposal in priority order, minors badged, going out at 10:00",
         %{workshop: w} do
      first = waiting_person_fixture(~U[2025-01-01 12:00:00Z], first_name: "Aoife")

      _minor =
        waiting_person_fixture(~U[2025-02-01 12:00:00Z],
          first_name: "Bea",
          date_of_birth: ~D[2009-01-01]
        )

      _third = waiting_person_fixture(~U[2025-03-01 12:00:00Z], first_name: "Cian")
      _fourth = waiting_person_fixture(~U[2025-04-01 12:00:00Z], first_name: "Dara")

      assert %{
               workshop: %{stage: :before_contact_from},
               next_batch: next,
               batches: [],
               attention: []
             } = console(w, ~U[2026-10-19 12:00:00Z])

      assert %{
               status: :scheduled,
               goes_out_at: ~U[2026-10-20 09:00:00Z],
               number: 1,
               size: 3,
               capacity: 3,
               paid: 0
             } = next

      assert [
               %{first_name: "Aoife", minor: false, queue_date: queue_date},
               %{first_name: "Bea", minor: true},
               %{first_name: "Cian", minor: false}
             ] = next.people

      assert queue_date == first.initial_registration_date
    end

    test "the preview is exactly what the pass sends", %{workshop: w} do
      waiting_people_fixture(5)
      preview = console(w, @batch_1_at).next_batch
      assert preview.status == :due

      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      sent =
        from(i in Intake, where: i.workshop_id == ^w.id, order_by: [i.queue_date, i.id])
        |> Repo.all()
        |> Enum.map(& &1.queue_date)

      assert sent == Enum.map(preview.people, & &1.queue_date)
    end

    test "during a window: the next Batch goes the morning after it ends, sized capacity − paid",
         %{workshop: w} do
      waiting_people_fixture(6)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      [paid | _] = Repo.all(from(i in Intake, where: i.workshop_id == ^w.id))
      force_intake_state!(paid.id, "paid")

      assert %{
               workshop: %{stage: :window_open},
               batches: [%{number: 1, size: 3, window_ends_at: window_end}],
               next_batch: %{
                 status: :scheduled,
                 goes_out_at: ~U[2026-10-28 10:00:00Z],
                 number: 2,
                 size: 2,
                 paid: 1,
                 people: people
               }
             } = console(w, ~U[2026-10-22 12:00:00Z])

      assert window_end == ~U[2026-10-27 23:59:59.999999Z]
      assert Enum.count(people) == 2
    end

    test "while paused the preview says so and still shows who is next",
         %{workshop: w, coordinator: coordinator} do
      waiting_people_fixture(2)

      assert {:ok, _} =
               BeginnersWorkshops.execute({:staff, coordinator}, {:pause_batches, w.id},
                 clock: Clock.fixed(~U[2026-10-19 12:00:00Z])
               )

      assert %{
               workshop: %{stage: :batches_paused},
               next_batch: %{status: :paused, goes_out_at: nil, people: [_, _]},
               pause: %{paused: true, paused_by: "Test Member", paused_at: %DateTime{}}
             } = console(w, @batch_1_at)
    end

    test "full: no Batch until a seat frees; after the cutoff: closed", %{workshop: w} do
      waiting_people_fixture(5)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      for intake <- Repo.all(from(i in Intake, where: i.workshop_id == ^w.id)),
          do: force_intake_state!(intake.id, "paid")

      assert %{workshop: %{stage: :full}, next_batch: %{status: :full, size: 0, people: []}} =
               console(w, ~U[2026-10-28 12:00:00Z])

      assert %{workshop: %{stage: :payment_closed}, next_batch: %{status: :closed}} =
               console(w, ~U[2026-11-11 18:30:00Z])
    end

    test "free seats with nobody waiting need attention", %{workshop: w} do
      assert %{next_batch: %{status: :due, people: []}, attention: [:nobody_waiting]} =
               console(w, @batch_1_at)

      waiting_people_fixture(1)
      assert %{attention: []} = console(w, @batch_1_at)
    end
  end

  describe "the roster" do
    test "groups Intakes as seated (paid), asked (contacted) and out", %{workshop: w} do
      waiting_people_fixture(3)
      assert {:ok, %{outcome: :sent}} = send_due(w, @batch_1_at)

      [seated, asked, out] =
        Repo.all(from(i in Intake, where: i.workshop_id == ^w.id, order_by: [i.queue_date]))

      force_intake_state!(seated.id, "paid")
      force_intake_state!(out.id, "declined")

      assert %{roster: %{seated: [s], asked: [a], out: [o]}} = console(w, @batch_1_at)
      assert %{id: id, state: "paid", origin: "batch", batch_number: 1, minor: false} = s
      assert id == seated.id
      assert a.id == asked.id
      assert o.id == out.id
      assert is_binary(a.first_name)
    end
  end
end
