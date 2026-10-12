defmodule Dhc.BeginnersWorkshops.InvitationHandoffTest do
  @moduledoc """
  ALE-392: the Invitation handoff. `invite` (`members.invite`) issues one
  attended person's Invitation through `Dhc.Onboarding.issue_invitation/3`
  and moves their standing `attended → invited` in the same transaction;
  deleting that Invitation returns the standing to `attended` on the
  Onboarding side; the Invitable view lists everyone `attended`; the
  console counts attended · invited · joined.

  The workshop is Saturday 24 October 2026 at 11:00 Dublin; people are
  checked in during it and the workshop is finished at the door, so every
  state comes from the real commands.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Intake, IntakeEmailLog}
  alias Dhc.Invitations
  alias Dhc.Invitations.{Invitation, ProcessingLog}
  alias Dhc.Waitlist.WaitlistEntry

  @during ~U[2026-10-24 10:30:00.000000Z]
  # 10:00 Dublin the morning after (GMT after the clocks go back).
  @follow_up ~U[2026-10-25 10:00:00.000000Z]

  setup do
    coordinator = staff_fixture()

    workshop =
      scheduled_fixture(coordinator, %{"date" => "2026-10-24", "start_time" => "11:00"})

    attended = paid_person_fixture!(workshop.id, first_name: "Niamh")
    absent = paid_person_fixture!(workshop.id, first_name: "Oisín")

    %{coordinator: coordinator, workshop: workshop, attended: attended, absent: absent}
  end

  defp finalise!(ctx, checked_in) do
    for intake <- checked_in do
      {:ok, _} =
        BeginnersWorkshops.execute(
          {:staff, ctx.coordinator},
          {:check_in, ctx.workshop.id, intake.id},
          clock: clock(@during)
        )
    end

    {:ok, %{outcome: :finalised}} =
      BeginnersWorkshops.execute({:staff, ctx.coordinator}, {:finish_workshop, ctx.workshop.id},
        clock: clock(@during)
      )

    :ok
  end

  defp invite(actor, ctx, intake),
    do: BeginnersWorkshops.execute({:staff, actor}, {:invite, ctx.workshop.id, intake.id})

  defp standing(%Intake{waitlist_id: id}), do: Repo.get!(WaitlistEntry, id).status

  defp invitations_for(%Intake{waitlist_id: id}),
    do: Repo.all(from(i in Invitation, where: i.waitlist_id == ^id))

  defp email_of(%Intake{waitlist_id: id}), do: Repo.get!(WaitlistEntry, id).email

  describe "invite" do
    setup ctx do
      :ok = finalise!(ctx, [ctx.attended])
      :ok
    end

    test "issues the standard Invitation for the Waitlist person and moves them to invited",
         ctx do
      assert {:ok, invited} = invite(ctx.coordinator, ctx, ctx.attended)

      assert [%Invitation{} = invitation] = invitations_for(ctx.attended)
      assert invited.invitation_id == invitation.id
      assert invited.standing == "invited"
      assert invitation.status == "pending"
      assert invitation.pricing_tier == "standard"
      assert invitation.email == email_of(ctx.attended)
      assert invitation.first_name == "Niamh"
      assert invitation.date_of_birth == ~D[1995-05-05]
      assert invitation.created_by_principal_id == ctx.coordinator

      assert standing(ctx.attended) == "invited"
      # The Intake keeps its attendance; the standing carries the handoff.
      assert Repo.get!(Intake, ctx.attended.id).state == "attended"

      assert [%Oban.Job{args: args}] =
               all_enqueued(worker: Dhc.Email.Worker)
               |> Enum.filter(&(&1.args["transactional_id"] == "inviteMember"))

      assert args["email"] == invitation.email
    end

    test "does not wait for the Follow-up", ctx do
      refute Repo.exists?(from(l in IntakeEmailLog, where: l.occasion == "follow_up"))
      assert {:ok, _invited} = invite(ctx.coordinator, ctx, ctx.attended)
    end

    test "refuses a second Invitation for the same person", ctx do
      assert {:ok, _invited} = invite(ctx.coordinator, ctx, ctx.attended)
      assert {:error, :already_invited} = invite(ctx.coordinator, ctx, ctx.attended)
      assert [_one] = invitations_for(ctx.attended)
    end

    test "refuses a no-show", ctx do
      assert Repo.get!(Intake, ctx.absent.id).state == "no_show"
      assert {:error, :not_attended} = invite(ctx.coordinator, ctx, ctx.absent)
      assert invitations_for(ctx.absent) == []
    end

    test "refuses a person who joined or left the queue", ctx do
      set_standing!(ctx.attended, "joined")
      assert {:error, :already_joined} = invite(ctx.coordinator, ctx, ctx.attended)

      set_standing!(ctx.attended, "removed")
      assert {:error, :not_invitable} = invite(ctx.coordinator, ctx, ctx.attended)
      assert invitations_for(ctx.attended) == []
    end

    test "refuses an email that belongs to a Principal, logging the refusal", ctx do
      email = email_of(ctx.attended)
      {:ok, _principal} = Dhc.Auth.register_principal(%{email: email})

      assert {:error, :email_is_principal} = invite(ctx.coordinator, ctx, ctx.attended)
      assert standing(ctx.attended) == "attended"
      assert invitations_for(ctx.attended) == []

      assert [%ProcessingLog{failure_count: 1} = log] =
               Repo.all(from(l in ProcessingLog, where: l.principal_id == ^ctx.coordinator))

      assert [%{"email" => ^email, "success" => false}] = log.results["items"]
    end

    test "refuses an email with a pending Invitation", ctx do
      email = email_of(ctx.attended)
      insert_pending_invitation!(email)

      assert {:error, :email_has_pending_invitation} =
               invite(ctx.coordinator, ctx, ctx.attended)

      assert standing(ctx.attended) == "attended"
    end

    test "refuses an unknown Intake, or one from another workshop", ctx do
      assert {:error, :not_found} =
               BeginnersWorkshops.execute(
                 {:staff, ctx.coordinator},
                 {:invite, ctx.workshop.id, Ecto.UUID.generate()}
               )

      other = scheduled_fixture(ctx.coordinator)

      assert {:error, :not_found} =
               BeginnersWorkshops.execute(
                 {:staff, ctx.coordinator},
                 {:invite, other.id, ctx.attended.id}
               )
    end

    test "needs members.invite before any read", ctx do
      coach = staff_fixture("coach")
      assert {:error, :forbidden} = invite(coach, ctx, ctx.attended)

      officer = staff_fixture("committee_coordinator")
      assert {:ok, _invited} = invite(officer, ctx, ctx.attended)
    end
  end

  test "refuses before Attendance Finalisation", ctx do
    force_intake_state!(ctx.attended.id, "attended")
    set_standing!(ctx.attended, "attended")

    assert {:error, :not_finalised} = invite(ctx.coordinator, ctx, ctx.attended)
    assert invitations_for(ctx.attended) == []
  end

  describe "deleting the Invitation" do
    setup ctx do
      :ok = finalise!(ctx, [ctx.attended])
      {:ok, invited} = invite(ctx.coordinator, ctx, ctx.attended)
      %{invitation_id: invited.invitation_id}
    end

    test "returns the standing to attended, so the person is Invitable again", ctx do
      assert :ok = Invitations.delete_many([ctx.invitation_id])

      assert standing(ctx.attended) == "attended"
      assert [%{intake_id: intake_id}] = BeginnersWorkshops.invitable()
      assert intake_id == ctx.attended.id

      assert {:ok, %{standing: "invited"}} = invite(ctx.coordinator, ctx, ctx.attended)
    end

    test "keeps the standing while another Invitation for the person remains", ctx do
      email = email_of(ctx.attended)
      entry_id = ctx.attended.waitlist_id

      other =
        Repo.insert!(%Invitation{
          email: email,
          waitlist_id: entry_id,
          prospective_principal_id: Ecto.UUID.generate(),
          status: "expired",
          expires_at: DateTime.utc_now() |> DateTime.truncate(:second),
          invitation_type: "beginners_workshop",
          pricing_tier: "standard"
        })

      assert :ok = Invitations.delete_many([ctx.invitation_id])
      assert standing(ctx.attended) == "invited"

      assert :ok = Invitations.delete_many([other.id])
      assert standing(ctx.attended) == "attended"
    end

    test "leaves a joined person joined", ctx do
      set_standing!(ctx.attended, "joined")
      assert :ok = Invitations.delete_many([ctx.invitation_id])
      assert standing(ctx.attended) == "joined"
    end

    test "a direct Invitation without a waitlist_id changes no standing", ctx do
      direct = insert_pending_invitation!("direct-#{System.unique_integer([:positive])}@x.ie")
      assert :ok = Invitations.delete_many([direct.id])
      assert standing(ctx.attended) == "invited"
    end
  end

  describe "the Invitable view" do
    test "lists attended people with the workshop date and the Follow-up's status", ctx do
      :ok = finalise!(ctx, [ctx.attended])

      assert [row] = BeginnersWorkshops.invitable()
      assert row.intake_id == ctx.attended.id
      assert row.workshop_id == ctx.workshop.id
      assert row.workshop_date == ~D[2026-10-24]
      assert row.first_name == "Niamh"
      assert row.email == email_of(ctx.attended)
      assert %{status: :scheduled, at: at} = row.follow_up
      assert DateTime.compare(at, @follow_up) == :eq

      {:ok, %{follow_ups: 1}} =
        BeginnersWorkshops.execute(:system, {:send_follow_ups, ctx.workshop.id},
          clock: clock(@follow_up)
        )

      assert [%{follow_up: %{status: :sent}}] = BeginnersWorkshops.invitable()
    end

    test "drops a person once invited", ctx do
      :ok = finalise!(ctx, [ctx.attended])
      {:ok, _invited} = invite(ctx.coordinator, ctx, ctx.attended)

      assert BeginnersWorkshops.invitable() == []
    end

    test "lists nobody before finalisation", _ctx do
      assert BeginnersWorkshops.invitable() == []
    end
  end

  describe "the console" do
    test "counts attended · invited · joined and carries each person's standing", ctx do
      second = paid_person_fixture!(ctx.workshop.id, first_name: "Sadhbh")
      third = paid_person_fixture!(ctx.workshop.id, first_name: "Tadhg")
      :ok = finalise!(ctx, [ctx.attended, second, third])

      {:ok, _invited} = invite(ctx.coordinator, ctx, ctx.attended)
      {:ok, _invited} = invite(ctx.coordinator, ctx, second)
      set_standing!(second, "joined")

      {:ok, console} = BeginnersWorkshops.workshop_console(ctx.workshop.id, clock: clock(@during))

      assert console.finalisation.invitations == %{attended: 3, invited: 1, joined: 1}

      assert console.roster.attended |> Map.new(&{&1.id, &1.standing}) == %{
               ctx.attended.id => "invited",
               second.id => "joined",
               third.id => "attended"
             }
    end
  end

  # Test-only: stands in for Invitation acceptance (`invited → joined`) or a
  # coordinator's removal.
  defp set_standing!(%Intake{waitlist_id: id}, status) do
    Repo.get!(WaitlistEntry, id)
    |> Ecto.Changeset.change(
      status: status,
      removed_at: if(status == "removed", do: DateTime.utc_now() |> DateTime.truncate(:second))
    )
    |> Repo.update!()
  end

  defp insert_pending_invitation!(email) do
    Repo.insert!(%Invitation{
      email: email,
      prospective_principal_id: Ecto.UUID.generate(),
      status: "pending",
      expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second),
      invitation_type: "admin",
      pricing_tier: "standard"
    })
  end
end
