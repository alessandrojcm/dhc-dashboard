defmodule Dhc.BeginnersWorkshops.StaffTest do
  @moduledoc """
  ALE-379: `set_staff` through `Dhc.BeginnersWorkshops.execute/3` — who may
  be assigned, the coach leaving the assistants, the refusals, access
  following immediately, the keyed Notifications signalled after commit, and
  optional Staff on `schedule_workshop`.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.StaffAssignment
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  setup do
    coordinator = staff_fixture()
    workshop = scheduled_fixture(coordinator)
    %{coordinator: coordinator, workshop: workshop}
  end

  defp set_staff(actor, workshop_id, coach, assistants \\ []) do
    BeginnersWorkshops.execute(
      {:staff, actor},
      {:set_staff, workshop_id,
       %{"coach_principal_id" => coach, "assistant_principal_ids" => assistants}},
      clock: clock()
    )
  end

  defp coach_fixture(attrs \\ %{}), do: staff_fixture("coach", attrs)
  defp member_fixture(attrs \\ %{}), do: staff_fixture("member", attrs)

  defp ids(%{coach: coach, assistants: assistants}),
    do: {coach && coach.principal_id, Enum.map(assistants, & &1.principal_id)}

  defp notifications(principal_id),
    do: Repo.all(from(n in Notification, where: n.principal_id == ^principal_id))

  # Bodies, sorted: rows created in the same second have no reliable order.
  defp bodies(principal_id),
    do: principal_id |> notifications() |> Enum.map(& &1.body) |> Enum.sort()

  defp rows(workshop_id),
    do: Repo.all(from(s in StaffAssignment, where: s.workshop_id == ^workshop_id))

  describe "set_staff" do
    test "assigns one coach and any active Members as assistants, coaches included", ctx do
      coach = coach_fixture(%{first_name: "Aoife", last_name: "Coach"})
      other_coach = coach_fixture(%{first_name: "Brian", last_name: "Coach"})
      assistant = member_fixture(%{first_name: "Cara", last_name: "Member"})

      assert {:ok, view} =
               set_staff(ctx.coordinator, ctx.workshop.id, coach, [assistant, other_coach])

      assert view.staff.coach == %{principal_id: coach, name: "Aoife Coach"}
      assert Enum.map(view.staff.assistants, & &1.name) == ["Brian Coach", "Cara Member"]
      assert view.alerts == []
    end

    test "the coordinator may assign themselves", ctx do
      Repo.insert!(%UserRole{principal_id: ctx.coordinator, role: "coach"})
      assert {:ok, view} = set_staff(ctx.coordinator, ctx.workshop.id, ctx.coordinator)
      assert ids(view.staff) == {ctx.coordinator, []}
    end

    test "a person picked as coach is removed from the assistants", ctx do
      coach = coach_fixture()
      assistant = member_fixture()

      assert {:ok, view} =
               set_staff(ctx.coordinator, ctx.workshop.id, coach, [assistant, coach, assistant])

      assert ids(view.staff) == {coach, [assistant]}

      # An assistant promoted to coach leaves the assistants too.
      promoted = coach_fixture()
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach, [promoted])

      assert {:ok, view} =
               set_staff(ctx.coordinator, ctx.workshop.id, promoted, [promoted, coach])

      assert ids(view.staff) == {promoted, [coach]}
      assert [_, _] = rows(ctx.workshop.id)
    end

    test "replaces the whole Staff list, and an empty one leaves the workshop Unstaffed", ctx do
      coach = coach_fixture()
      assistant = member_fixture()
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach, [assistant])

      assert {:ok, view} = set_staff(ctx.coordinator, ctx.workshop.id, nil, [])
      assert ids(view.staff) == {nil, []}
      assert view.alerts == [:unstaffed]
      assert rows(ctx.workshop.id) == []
    end

    test "only a workshop with no Staff at all is Unstaffed: assistants alone staff it", ctx do
      assert {:ok, view} = set_staff(ctx.coordinator, ctx.workshop.id, nil, [member_fixture()])
      assert view.alerts == []
    end

    test "the coach must hold the coach role at assignment", ctx do
      assert {:error, :not_a_coach} =
               set_staff(ctx.coordinator, ctx.workshop.id, member_fixture())

      inactive_coach = coach_fixture(%{is_active: false})
      assert {:error, :not_a_coach} = set_staff(ctx.coordinator, ctx.workshop.id, inactive_coach)
      assert rows(ctx.workshop.id) == []
    end

    test "assistants must be active Members", ctx do
      inactive = member_fixture(%{is_active: false})
      no_profile = Dhc.AuthFixtures.principal_fixture().id

      for assistant <- [inactive, no_profile, Ecto.UUID.generate()] do
        assert {:error, :not_a_member} =
                 set_staff(ctx.coordinator, ctx.workshop.id, nil, [member_fixture(), assistant])
      end

      assert rows(ctx.workshop.id) == []
    end

    test "a coach whose coach role is removed later keeps the assignment", ctx do
      coach = coach_fixture()
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach)

      Repo.delete_all(from(r in UserRole, where: r.principal_id == ^coach and r.role == "coach"))

      # Re-saving the Staff with the same coach (e.g. adding an assistant) is
      # not a new coach assignment, so it is not refused.
      assistant = member_fixture()
      assert {:ok, view} = set_staff(ctx.coordinator, ctx.workshop.id, coach, [assistant])
      assert ids(view.staff) == {coach, [assistant]}

      # Assigning them as coach afresh, elsewhere, is.
      other = scheduled_fixture(ctx.coordinator)
      assert {:error, :not_a_coach} = set_staff(ctx.coordinator, other.id, coach)
    end

    test "is refused after finalisation and on a cancelled workshop", ctx do
      coach = coach_fixture()
      force_status!(ctx.workshop.id, "finalised")
      assert {:error, :after_finalisation} = set_staff(ctx.coordinator, ctx.workshop.id, coach)

      cancelled = scheduled_fixture(ctx.coordinator)
      force_status!(cancelled.id, "cancelled")
      assert {:error, :already_cancelled} = set_staff(ctx.coordinator, cancelled.id, coach)
    end

    test "refuses unknown workshops and malformed Staff", ctx do
      assert {:error, :not_found} = set_staff(ctx.coordinator, Ecto.UUID.generate(), nil)
      assert {:error, :not_found} = set_staff(ctx.coordinator, "nope", nil)
      assert {:error, :invalid_staff} = set_staff(ctx.coordinator, ctx.workshop.id, "nope")
      assert {:error, :invalid_staff} = set_staff(ctx.coordinator, ctx.workshop.id, nil, ["x"])

      assert {:error, :invalid_staff} =
               BeginnersWorkshops.execute(
                 {:staff, ctx.coordinator},
                 {:set_staff, ctx.workshop.id, %{"assistant_principal_ids" => "x"}},
                 clock: clock()
               )
    end

    test "only the workshop managers may set Staff; assigned Staff may not", ctx do
      coach = coach_fixture()
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach)

      for actor <- [coach, staff_fixture("workshop_coordinator"), member_fixture()] do
        assert {:error, :forbidden} = set_staff(actor, ctx.workshop.id, nil)
      end

      assert {:error, :forbidden} = set_staff(member_fixture(), Ecto.UUID.generate(), nil)
    end

    test "access follows immediately", ctx do
      coach = coach_fixture()
      session = fn id -> elem(Dhc.Auth.load_session_principal(%{id: id}), 1) end
      run = :"beginners.workshops.run"

      authorized? = fn id ->
        {:ok, _view, resource} = BeginnersWorkshops.door_view(ctx.workshop.id, clock: clock())
        Dhc.Auth.Capabilities.authorize(session.(id), run, resource) == :ok
      end

      refute authorized?.(coach)
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach)
      assert authorized?.(coach)
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, nil)
      refute authorized?.(coach)
    end
  end

  describe "Staff Notifications" do
    test "the people added and removed are notified once each, the person making the change included",
         ctx do
      coach = coach_fixture()
      assistant = member_fixture()

      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach, [assistant])

      assert [
               %{
                 body:
                   "You're the coach for the Beginners' Workshop on Sat 14 Nov 2026 at 18:30, St. Andrew's Hall."
               }
             ] =
               notifications(coach)

      assert [%{body: "You're assisting at the Beginners' Workshop on " <> _}] =
               notifications(assistant)

      # Unchanged Staff are not notified again.
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach, [assistant])
      assert [_] = notifications(coach)

      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach, [])

      assert [
               "You're assisting at the Beginners' Workshop on Sat 14 Nov 2026 at 18:30, St. Andrew's Hall.",
               "You're no longer on the Staff for the Beginners' Workshop on Sat 14 Nov 2026 at 18:30, St. Andrew's Hall."
             ] = bodies(assistant)

      # Assigned again: a new assignment, so a new Notification.
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach, [assistant])
      assert [_, _, _] = notifications(assistant)

      Repo.insert!(%UserRole{principal_id: ctx.coordinator, role: "coach"})
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, ctx.coordinator)

      assert ["You're the coach for the Beginners' Workshop on " <> _] =
               bodies(ctx.coordinator)

      assert [_, _] = notifications(coach)
    end

    test "a role change notifies the new role only", ctx do
      coach = coach_fixture()
      other = coach_fixture()
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach, [other])
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, other, [coach])

      assert [
               "You're assisting at" <> _,
               "You're the coach for" <> _
             ] = bodies(coach)

      assert [
               "You're assisting at" <> _,
               "You're the coach for" <> _
             ] = bodies(other)

      refute Enum.any?(
               bodies(coach) ++ bodies(other),
               &String.starts_with?(&1, "You're no longer")
             )
    end

    test "are signalled after commit, so Web Push delivers them", ctx do
      coach = coach_fixture()
      {:ok, _} = set_staff(ctx.coordinator, ctx.workshop.id, coach)

      assert [%{id: id}] = notifications(coach)

      assert_enqueued(
        worker: Dhc.Notifications.Workers.WebPushWorker,
        args: %{notification_id: id}
      )
    end

    test "a refused change notifies nobody", ctx do
      assistant = member_fixture()

      assert {:error, :not_a_coach} =
               set_staff(ctx.coordinator, ctx.workshop.id, member_fixture(), [assistant])

      assert notifications(assistant) == []
      refute_enqueued(worker: Dhc.Notifications.Workers.WebPushWorker)
    end
  end

  describe "schedule_workshop with optional Staff" do
    test "assigns the Staff to every scheduled workshop and notifies them", ctx do
      coach = coach_fixture()
      assistant = member_fixture()

      assert {:ok, [first, second]} =
               BeginnersWorkshops.execute(
                 {:staff, ctx.coordinator},
                 {:schedule_workshop,
                  [
                    workshop_attrs(%{
                      "coach_principal_id" => coach,
                      "assistant_principal_ids" => [assistant, coach]
                    }),
                    workshop_attrs(%{"date" => "2026-11-21", "coach_principal_id" => coach})
                  ]},
                 clock: clock()
               )

      assert ids(first.staff) == {coach, [assistant]}
      assert ids(second.staff) == {coach, []}
      assert first.alerts == [] and second.alerts == []
      assert [_, _] = notifications(coach)
    end

    test "is all or nothing: a refused coach names its workshop and schedules none", ctx do
      before = Repo.aggregate(Dhc.BeginnersWorkshops.BeginnersWorkshop, :count)

      assert {:error, {:workshop, 1, :not_a_coach}} =
               BeginnersWorkshops.execute(
                 {:staff, ctx.coordinator},
                 {:schedule_workshop,
                  [
                    workshop_attrs(%{"coach_principal_id" => coach_fixture()}),
                    workshop_attrs(%{"coach_principal_id" => member_fixture()})
                  ]},
                 clock: clock()
               )

      assert Repo.aggregate(Dhc.BeginnersWorkshops.BeginnersWorkshop, :count) == before
    end
  end
end
