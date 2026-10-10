defmodule Dhc.E2EHarnessBeginnersWorkshopTest do
  @moduledoc """
  ALE-398: the named Beginners' Workshop scenarios behind the E2E journey,
  run in order on the wall clock exactly as the Playwright spec runs them:
  schedule, the fixed-10:00 Batch, the Intake link, Pay (Stripe stubbed),
  the completed Checkout stand-in, the workshop day at the door, and the
  Carried Fee holder's path.
  """

  use Dhc.DataCase, async: false

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Batch, Intake, IntakeLink}
  alias Dhc.E2EHarness
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  setup do
    E2EHarness.seed("waitlistStatus", %{"isOpen" => true})
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp person(first_name, registered_at) do
    E2EHarness.seed("waitlist", %{
      "email" =>
        "#{String.downcase(first_name)}-#{System.unique_integer([:positive])}@example.com",
      "firstName" => first_name,
      "initialRegistrationDate" => registered_at
    })
  end

  defp token(path), do: path |> String.split("/") |> List.last()

  test "reset keeps the migration-seeded Intake Email templates a Batch needs" do
    templates = length(Dhc.BeginnersWorkshops.IntakeEmails.list_templates())
    assert templates > 0

    :ok = E2EHarness.reset!()

    assert length(Dhc.BeginnersWorkshops.IntakeEmails.list_templates()) == templates
    assert Repo.aggregate(WaitlistEntry, :count) == 0
  end

  test "waitlist seeds take an explicit priority" do
    seeded = person("Early", "2000-01-01T09:00:00Z")

    assert Repo.get!(WaitlistEntry, seeded.waitlistId).initial_registration_date ==
             ~U[2000-01-01 09:00:00Z]
  end

  test "the journey scenarios: Batch at 10:00, Intake link, payment and the door", %{
    coordinator: coordinator
  } do
    _younger = person("Later", "2020-01-01T09:00:00Z")
    seeded = person("Journey", "2000-01-01T09:00:00Z")

    workshop = E2EHarness.seed("beginnersWorkshop", %{"actorId" => coordinator})
    assert workshop.date == Date.to_iso8601(Date.add(Dhc.ClubCalendar.today(), 14))

    batch = E2EHarness.seed("beginnersWorkshopBatch", %{"workshopId" => workshop.workshopId})
    assert batch.outcome == "sent"
    assert batch.contactedWaitlistIds == [seeded.waitlistId]

    sent_at = Repo.one!(from(b in Batch, where: b.workshop_id == ^workshop.workshopId)).sent_at
    assert sent_at |> Dhc.ClubCalendar.time_on() |> Time.truncate(:second) == ~T[10:00:00]

    # A second pass while the window is open sends nothing: an error.
    assert {:error, :not_due} =
             E2EHarness.seed("beginnersWorkshopBatch", %{"workshopId" => workshop.workshopId})

    link = E2EHarness.seed("beginnersWorkshopIntakeLink", %{"waitlistId" => seeded.waitlistId})
    assert link.workshopId == workshop.workshopId
    assert "/beginners/intake/" <> token = link.path
    assert {:ok, %{state: :pay}} = BeginnersWorkshops.intake_page(token)

    assert {:error, :no_checkout_session} =
             E2EHarness.seed("beginnersWorkshopPayment", %{"waitlistId" => seeded.waitlistId})

    Stripe.stub_create()

    assert {:ok, %{checkout_url: _url}} =
             BeginnersWorkshops.execute({:intake_link, token(link.path)}, :start_payment)

    payment = E2EHarness.seed("beginnersWorkshopPayment", %{"waitlistId" => seeded.waitlistId})
    assert payment.outcome == "paid"
    assert payment.sessionId =~ "cs_"
    assert {:ok, %{state: :paid}} = BeginnersWorkshops.intake_page(token)

    door = E2EHarness.seed("beginnersWorkshopDoorOpen", %{"workshopId" => workshop.workshopId})
    assert door.date == Date.to_iso8601(Dhc.ClubCalendar.today())

    assistant = staff_fixture("member")
    set_staff!(workshop.workshopId, nil, [assistant])
    intake = Repo.get!(Intake, link.intakeId)

    assert {:ok, _door} =
             BeginnersWorkshops.execute(
               {:staff, assistant},
               {:check_in, workshop.workshopId, intake.id}
             )
  end

  test "a Carried Fee holder is contacted to confirm", %{coordinator: coordinator} do
    holder = person("Holder", "1999-01-01T09:00:00Z")

    fee = E2EHarness.seed("beginnersWorkshopCarriedFee", %{"waitlistId" => holder.waitlistId})
    assert fee.status == "held"

    workshop =
      E2EHarness.seed("beginnersWorkshop", %{
        "actorId" => coordinator,
        "venue" => "Carried Fee Hall",
        "date" => Date.to_iso8601(Date.add(Dhc.ClubCalendar.today(), 21))
      })

    assert workshop.venue == "Carried Fee Hall"

    assert %{contactedWaitlistIds: [id]} =
             E2EHarness.seed("beginnersWorkshopBatch", %{"workshopId" => workshop.workshopId})

    assert id == holder.waitlistId

    link = E2EHarness.seed("beginnersWorkshopIntakeLink", %{"waitlistId" => holder.waitlistId})
    assert {:ok, %{state: :confirm}} = BeginnersWorkshops.intake_page(token(link.path))
    assert IntakeLink.hash(token(link.path)) == Repo.get!(Intake, link.intakeId).link_token_hash
  end

  test "the Invitation scenario finds the handoff's Invitation" do
    seeded = person("Invitee", "2000-01-01T09:00:00Z")

    assert {:error, :no_invitation} =
             E2EHarness.seed("beginnersWorkshopInvitation", %{"waitlistId" => seeded.waitlistId})

    invitation =
      E2EHarness.seed("invitation", %{
        "email" => "invitee-#{System.unique_integer([:positive])}@example.com"
      })

    from(i in Dhc.Invitations.Invitation, where: i.id == ^invitation.invitationId)
    |> Repo.update_all(set: [waitlist_id: seeded.waitlistId])

    assert %{invitationId: id, status: "pending"} =
             E2EHarness.seed("beginnersWorkshopInvitation", %{"waitlistId" => seeded.waitlistId})

    assert id == invitation.invitationId
  end

  test "an Intake link for someone without an open Intake is an error" do
    seeded = person("Nobody", "2000-01-01T09:00:00Z")

    assert {:error, :no_open_intake} =
             E2EHarness.seed("beginnersWorkshopIntakeLink", %{"waitlistId" => seeded.waitlistId})
  end
end
