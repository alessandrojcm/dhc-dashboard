defmodule Dhc.E2EHarness.BeginnersWorkshops do
  @moduledoc false

  # ALE-398: the named Beginners' Workshop scenarios behind the E2E journey
  # (`apps/web/e2e/beginners-workshop-journey.spec.ts`). They stand in for
  # the two things a browser test cannot drive: the clock (the 10:00 Batch
  # pass, the workshop day arriving) and Stripe's hosted Checkout page (the
  # completed session). Every write but the workshop day goes through
  # `Dhc.BeginnersWorkshops.execute/3`, so the journey exercises the same
  # boundary production does.

  import Ecto.Query

  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, Intake, IntakeLink, IntakePayment}
  alias Dhc.ClubCalendar
  alias Dhc.Invitations.Invitation
  alias Dhc.Repo

  # The Batch pass sends from 10:00 Dublin (`WorkshopPolicy.batch_due?/3`).
  @batch_time ~T[10:00:00]

  # Schedules one workshop through the boundary as a staff actor (the
  # journey schedules its own through the UI; shorter paths use this).
  def seed("beginnersWorkshop", attrs) do
    today = ClubCalendar.today()

    workshop =
      %{
        "venue" => Map.get(attrs, "venue", "E2E Hall #{System.unique_integer([:positive])}"),
        "date" => Map.get(attrs, "date", Date.to_iso8601(Date.add(today, 14))),
        "start_time" => Map.get(attrs, "startTime", "18:30"),
        "capacity" => Map.get(attrs, "capacity", 1),
        "fee_cents" => Map.get(attrs, "feeCents", 4000)
      }

    with {:ok, [view]} <-
           BeginnersWorkshops.execute(
             {:staff, Map.fetch!(attrs, "actorId")},
             {:schedule_workshop, [workshop]}
           ) do
      %{
        workshopId: view.id,
        date: Date.to_iso8601(view.date),
        venue: view.venue
      }
    end
  end

  # The Batch pass for one workshop at 10:00 Dublin today, so a run does
  # not depend on the time of day. Anything but a sent Batch is an error:
  # the journey cannot continue without one.
  def seed("beginnersWorkshopBatch", %{"workshopId" => workshop_id}) do
    at = ClubCalendar.to_utc(ClubCalendar.today(), @batch_time)

    case BeginnersWorkshops.execute(:system, {:send_due_batch, workshop_id},
           clock: Clock.fixed(at)
         ) do
      {:ok, %{outcome: :sent}} ->
        %{
          outcome: "sent",
          sentAt: DateTime.to_iso8601(at),
          contactedWaitlistIds:
            Repo.all(
              from(i in Intake,
                where: i.workshop_id == ^workshop_id and i.state == "contacted",
                select: i.waitlist_id
              )
            )
        }

      {:ok, %{outcome: outcome}} ->
        {:error, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The person's Intake link, as the Contact email carries it: the path of
  # their open Intake's page at its current link generation.
  def seed("beginnersWorkshopIntakeLink", %{"waitlistId" => waitlist_id}) do
    with %Intake{} = intake <- open_intake(waitlist_id) do
      token = IntakeLink.token(intake.id, intake.link_generation)

      %{
        intakeId: intake.id,
        workshopId: intake.workshop_id,
        path: "/beginners/intake/#{token}"
      }
    end
  end

  # Stands in for Stripe's hosted Checkout page: the person's live Seat
  # Hold completes with exactly the amount it holds, through the same
  # `complete_payment` command the `checkout.session.completed` webhook runs.
  def seed("beginnersWorkshopPayment", %{"waitlistId" => waitlist_id}) do
    with %Intake{} = intake <- open_intake(waitlist_id),
         %IntakePayment{} = payment <- recorded_hold(intake.id),
         {:ok, %{outcome: outcome}} <-
           BeginnersWorkshops.execute(:stripe, {:complete_payment, completed_session(payment)}) do
      %{outcome: Atom.to_string(outcome), sessionId: payment.stripe_checkout_session_id}
    end
  end

  # Stands in for the clock reaching the workshop day: the workshop moves
  # to Dublin today, starting now, so check-in is open (the HTTP tests'
  # `force_today!/1`). Only the time facts change; its people stay as the
  # boundary left them.
  def seed("beginnersWorkshopDoorOpen", %{"workshopId" => workshop_id}) do
    %BeginnersWorkshop{} = workshop = BeginnersWorkshopFixtures.force_today!(workshop_id)

    %{
      workshopId: workshop.id,
      date: Date.to_iso8601(workshop.date),
      startTime: workshop.start_time |> Time.truncate(:second) |> Time.to_iso8601()
    }
  end

  # A `held` Carried Fee, as the spreadsheet import records one ("Paid" =
  # Yes), through the boundary's import command.
  def seed("beginnersWorkshopCarriedFee", %{"waitlistId" => waitlist_id}) do
    with {:ok, %{id: id, status: status}} <-
           BeginnersWorkshops.execute(:system, {:import_carried_fee, waitlist_id, "Yes"}) do
      %{carriedFeeId: id, status: status}
    end
  end

  # The Invitation the handoff issued to a Waitlist person, so the spec can
  # delete it (the `invitation` fixture) and leave the run's Invitation
  # list as other specs expect it.
  def seed("beginnersWorkshopInvitation", %{"waitlistId" => waitlist_id}) do
    from(i in Invitation,
      where: i.waitlist_id == ^waitlist_id,
      order_by: [desc: i.created_at],
      limit: 1,
      select: %{invitationId: i.id, status: i.status, invitationType: i.invitation_type}
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :no_invitation}
      invitation -> invitation
    end
  end

  defp open_intake(waitlist_id) do
    open = Intake.open_states()

    from(i in Intake,
      where: i.waitlist_id == ^waitlist_id and i.state in ^open,
      order_by: [desc: i.contacted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :no_open_intake}
      intake -> intake
    end
  end

  defp recorded_hold(intake_id) do
    from(p in IntakePayment,
      where:
        p.intake_id == ^intake_id and p.status == "open" and
          not is_nil(p.stripe_checkout_session_id)
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :no_checkout_session}
      payment -> payment
    end
  end

  defp completed_session(%IntakePayment{} = payment) do
    %{
      "id" => payment.stripe_checkout_session_id,
      "object" => "checkout.session",
      "status" => "complete",
      "payment_status" => "paid",
      "amount_total" => payment.amount_cents,
      "currency" => payment.currency,
      "payment_intent" => "pi_e2e_#{payment.id}",
      "metadata" => %{"type" => "beginners_intake_payment", "payment_id" => payment.id}
    }
  end
end
