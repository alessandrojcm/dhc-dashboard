defmodule Dhc.BeginnersWorkshops.DoorCheckInTest do
  @moduledoc """
  ALE-390: door check-in. `check_in` / `undo_check_in` at the edges of the
  check-in window, the paid-only rule, the assignment-scoped authorization
  (refused before any read), the record outliving an unassignment, and the
  door view's closed shape (never email, payment or Waitlist fields).
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Intake, WorkshopPolicy}

  # The fixture workshop: Sat 14 Nov 2026, 18:30 Dublin (GMT, so 18:30Z).
  @opens ~U[2026-11-14 17:30:00.000000Z]
  @during ~U[2026-11-14 18:45:00.000000Z]

  setup do
    coordinator = staff_fixture()
    coach = staff_fixture("coach", %{first_name: "Aoife", last_name: "Coach"})
    assistant = staff_fixture("member", %{first_name: "Brian", last_name: "Assist"})
    outsider = staff_fixture("member")
    workshop = scheduled_fixture(coordinator)
    set_staff!(workshop.id, coach, [assistant])

    %{
      coordinator: coordinator,
      coach: coach,
      assistant: assistant,
      outsider: outsider,
      workshop: workshop,
      intake: paid_person_fixture!(workshop.id, first_name: "Niamh")
    }
  end

  defp check_in(actor, ctx, at, intake \\ nil),
    do:
      BeginnersWorkshops.execute(
        {:staff, actor},
        {:check_in, ctx.workshop.id, (intake || ctx.intake).id},
        clock: clock(at)
      )

  defp undo(actor, ctx, at),
    do:
      BeginnersWorkshops.execute(
        {:staff, actor},
        {:undo_check_in, ctx.workshop.id, ctx.intake.id},
        clock: clock(at)
      )

  describe "the check-in window" do
    test "opens exactly an hour before the start", ctx do
      assert {:error, :check_in_not_open} =
               check_in(ctx.assistant, ctx, DateTime.add(@opens, -1, :second))

      assert {:error, :check_in_not_open} = check_in(ctx.assistant, ctx, ~U[2026-11-13 20:00:00Z])

      assert {:ok, %{checked_in_at: @opens, checked_in_by_principal_id: by}} =
               check_in(ctx.assistant, ctx, @opens)

      assert by == ctx.assistant
    end

    test "stays open until the end of that Dublin day, then closes", ctx do
      last = ~U[2026-11-14 23:59:59.999999Z]
      assert {:ok, %{checked_in_at: ^last}} = check_in(ctx.coach, ctx, last)
      assert {:ok, %{checked_in_at: nil}} = undo(ctx.coach, ctx, last)

      assert {:error, :check_in_closed} = check_in(ctx.coach, ctx, ~U[2026-11-15 00:00:00Z])
      assert {:error, :check_in_closed} = undo(ctx.coach, ctx, ~U[2026-11-15 00:00:00Z])
    end

    test "closes at Attendance Finalisation, even on the day", ctx do
      force_status!(ctx.workshop.id, "finalised")
      assert {:error, :check_in_closed} = check_in(ctx.coach, ctx, @during)

      force_status!(ctx.workshop.id, "cancelled")
      assert {:error, :check_in_closed} = check_in(ctx.coach, ctx, @during)
    end

    test "is judged on the Dublin day in summer time" do
      workshop = %Dhc.BeginnersWorkshops.BeginnersWorkshop{
        status: "scheduled",
        date: ~D[2026-06-13],
        start_time: ~T[10:00:00]
      }

      reading = fn now -> Dhc.BeginnersWorkshops.Clock.read(clock(now)) end

      # 09:00 IST is 08:00Z; 23:59 IST is 22:59Z.
      assert WorkshopPolicy.check_in_window(workshop, reading.(~U[2026-06-13 07:59:59Z])) ==
               :before

      assert WorkshopPolicy.check_in_window(workshop, reading.(~U[2026-06-13 08:00:00Z])) == :open
      assert WorkshopPolicy.check_in_window(workshop, reading.(~U[2026-06-13 22:59:59Z])) == :open

      assert WorkshopPolicy.check_in_window(workshop, reading.(~U[2026-06-13 23:00:00Z])) ==
               :closed
    end
  end

  describe "who may check people in" do
    test "only paid Intakes: no walk-ins and no unpaid people", ctx do
      person = waiting_person_fixture(~U[2025-02-01 12:00:00Z])
      {contacted, _token} = intake_fixture!(ctx.workshop.id, person)

      assert {:error, :not_paid} = check_in(ctx.coach, ctx, @during, contacted)

      other = scheduled_fixture(ctx.coordinator, %{"date" => "2026-11-21"})
      elsewhere = paid_person_fixture!(other.id)
      assert {:error, :not_found} = check_in(ctx.coach, ctx, @during, elsewhere)
    end

    test "the managers may, as Staff do", ctx do
      assert {:ok, %{checked_in_by_principal_id: by}} = check_in(ctx.coordinator, ctx, @during)
      assert by == ctx.coordinator
    end

    test "an unassigned principal is refused before any read, like an unknown workshop", ctx do
      {result, sources} = queried_sources(fn -> check_in(ctx.outsider, ctx, @during) end)

      assert result == {:error, :not_found}
      refute "beginners_workshops" in sources
      refute "beginners_workshop_intakes" in sources
      assert "beginners_workshop_staff" in sources

      assert {:error, :not_found} =
               BeginnersWorkshops.execute(
                 {:staff, ctx.outsider},
                 {:check_in, Ecto.UUID.generate(), ctx.intake.id},
                 clock: clock(@during)
               )

      assert {:error, :not_found} = undo(ctx.outsider, ctx, @during)
      assert Repo.get!(Intake, ctx.intake.id).checked_in_at == nil
    end

    test "the record stays when that Staff member is later unassigned", ctx do
      assert {:ok, _} = check_in(ctx.assistant, ctx, @during)
      set_staff!(ctx.workshop.id, ctx.coach, [], clock: clock(@during))

      assert {:error, :not_found} = undo(ctx.assistant, ctx, @during)

      {:ok, view, _resource} =
        BeginnersWorkshops.door_view(ctx.workshop.id, clock: clock(@during))

      assert [%{checked_in: %{by: "Brian Assist", at: @during}}] = view.people
    end
  end

  describe "check_in / undo_check_in" do
    test "are idempotent and keep the first record", ctx do
      assert {:ok, %{checked_in_at: first}} = check_in(ctx.assistant, ctx, @during)

      later = DateTime.add(@during, 60, :second)

      assert {:ok, %{checked_in_at: ^first, checked_in_by_principal_id: by}} =
               check_in(ctx.coach, ctx, later)

      assert by == ctx.assistant

      assert {:ok, %{checked_in_at: nil, checked_in_by_principal_id: nil}} =
               undo(ctx.coach, ctx, later)

      assert {:ok, %{checked_in_at: nil}} = undo(ctx.coach, ctx, later)
      assert Repo.get!(Intake, ctx.intake.id).state == "paid"
    end
  end

  describe "door_view/2" do
    test "carries the door list and window, and never email, payment or Waitlist fields", ctx do
      minor =
        paid_person_fixture!(ctx.workshop.id,
          first_name: "Ciara",
          # 18 the day after the workshop.
          date_of_birth: ~D[2008-11-15],
          medical_conditions: "Asthma",
          guardian: {"Gráinne", "Parent", "+353870000001"}
        )

      _adult_with_guardian =
        paid_person_fixture!(ctx.workshop.id,
          first_name: "Dara",
          date_of_birth: ~D[2008-11-14],
          guardian: {"Old", "Guardian", "+353870000002"}
        )

      person = waiting_person_fixture(~U[2025-03-01 12:00:00Z], first_name: "Zed")
      {_contacted, _token} = intake_fixture!(ctx.workshop.id, person)

      assert {:ok, _} = check_in(ctx.coach, ctx, @during)

      {:ok, view, _resource} =
        BeginnersWorkshops.door_view(ctx.workshop.id, clock: clock(DateTime.add(@opens, -60)))

      assert %{window: :before, opens_at: opens_at} = view.check_in
      assert DateTime.compare(opens_at, @opens) == :eq

      assert [ciara, dara, niamh] = view.people
      assert Enum.map(view.people, & &1.first_name) == ~w(Ciara Dara Niamh)

      for person <- view.people do
        assert Map.keys(person) |> Enum.sort() ==
                 ~w(checked_in first_name guardian id last_name medical_conditions minor pronouns state)a
      end

      assert %{
               id: minor_id,
               minor: true,
               medical_conditions: "Asthma",
               pronouns: "they/them",
               state: "paid",
               guardian: %{name: "Gráinne Parent", phone_number: "+353870000001"},
               checked_in: nil
             } = ciara

      assert minor_id == minor.id
      assert %{minor: false, guardian: nil} = dara
      assert %{checked_in: %{by: "Aoife Coach", at: @during}} = niamh

      text = inspect(view)
      refute text =~ "@waitlist.example.com"
      refute text =~ ~r/email|payment|refund|fee|waitlist|queue_date|date_of_birth/i
    end
  end

  # Every table the calling process queried while running `fun`.
  defp queried_sources(fun) do
    id = {__MODULE__, make_ref()}
    pid = self()
    Process.put(id, [])

    :ok =
      :telemetry.attach(
        id,
        [:dhc, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == pid, do: Process.put(id, [meta.source | Process.get(id)])
        end,
        nil
      )

    try do
      result = fun.()
      {result, Process.get(id) |> Enum.reject(&is_nil/1) |> Enum.uniq()}
    after
      :telemetry.detach(id)
    end
  end
end
