defmodule Dhc.BeginnersWorkshops.CarriedFeesConcurrencyTest do
  @moduledoc """
  ALE-388: `confirm` (a Carried Fee holder) racing `start_payment` (a payer)
  for the last seat, on real connections outside the SQL sandbox
  (`Dhc.ConcurrencyHelpers`), because a sandboxed connection serializes
  everything and cannot show a lock bug. Both take the seat under the
  Beginners' Workshop lock with the same rule, so exactly one wins and the
  other sees `full`, whichever runs first.
  """

  use Dhc.DataCase, async: false

  import Dhc.BeginnersWorkshopFixtures
  import Dhc.ConcurrencyHelpers

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakeLink,
    IntakePayment,
    LockTrace,
    WorkshopPolicy
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]

  defp run(actor, command),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(@now))

  test "confirm and start_payment on the last seat: exactly one takes it, the other sees full" do
    for _attempt <- 1..3 do
      committed(fn %{workshop: workshop, holder: holder, payer: payer} ->
        Stripe.stub_create()

        results =
          hold_lock_then(
            "SELECT id FROM beginners_workshops WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(workshop.id)],
            [
              fn -> {:confirm, run({:intake_link, holder.token}, :confirm)} end,
              fn -> {:pay, run({:intake_link, payer.token}, :start_payment)} end
            ]
          )

        winners =
          for {who, result} <- results,
              match?({:ok, %{outcome: :done}}, result) or
                match?({:ok, %{checkout_url: _}}, result),
              do: who

        assert [_winner] = winners
        assert Enum.count(results, fn {_who, result} -> result == {:error, :full} end) == 1

        paid =
          Repo.aggregate(
            from(i in Intake, where: i.workshop_id == ^workshop.id and i.state == "paid"),
            :count
          )

        holds =
          Repo.aggregate(
            from(p in IntakePayment, where: p.workshop_id == ^workshop.id and p.status == "open"),
            :count
          )

        assert paid + holds == 1

        fee = Repo.get!(CarriedFee, holder.fee_id)

        case winners do
          [:confirm] -> assert fee.status == "applied"
          [:pay] -> assert fee.status == "held"
        end
      end)
    end
  end

  test "confirm locks top-down and writes only inside a transaction" do
    committed(fn %{holder: holder} ->
      {result, events} = LockTrace.trace(fn -> run({:intake_link, holder.token}, :confirm) end)

      assert {:ok, %{outcome: :done}} = result
      assert LockTrace.upward_locks(events) == []
      assert LockTrace.writes_outside_transaction(events) == []

      assert LockTrace.transactions(events) == [
               ~w(beginners_workshops beginners_workshop_intakes beginners_workshop_carried_fees)
             ]
    end)
  end

  # A one-seat workshop with a contacted holder of a `held` Carried Fee and
  # a contacted payer, committed outside the sandbox and deleted afterwards.
  defp committed(fun) do
    ctx =
      outside_sandbox(fn ->
        workshop =
          %{
            venue: "Race Hall",
            date: ~D[2026-11-14],
            start_time: ~T[18:30:00],
            capacity: 1,
            fee_cents: 4000,
            payment_cutoff: ~U[2026-11-11 18:30:00.000000Z],
            contact_from: ~D[2026-10-20],
            payment_window_days: WorkshopPolicy.default_payment_window_days()
          }
          |> BeginnersWorkshop.schedule_changeset()
          |> Repo.insert!()

        [holder, payer] = people = waiting_people_fixture(2)

        fee =
          Repo.insert!(%CarriedFee{
            waitlist_id: holder.id,
            origin: "import",
            imported_paid_text: "Yes",
            status_changed_at: @now
          })

        [holder_intake, payer_intake] = intakes = Enum.map(people, &contact!(workshop, &1))

        %{
          workshop: workshop,
          people: people,
          intakes: intakes,
          fee_ids: [fee.id],
          holder: %{token: IntakeLink.token(holder_intake.id, 1), fee_id: fee.id},
          payer: %{token: IntakeLink.token(payer_intake.id, 1)}
        }
      end)

    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    outside_sandbox(fn -> fun.(ctx) end)
    outside_sandbox(fn -> cleanup!(ctx) end)
  end

  defp contact!(workshop, person) do
    id = Ecto.UUID.generate()

    %{
      id: id,
      workshop_id: workshop.id,
      waitlist_id: person.id,
      origin: "fast_track",
      queue_date: person.initial_registration_date,
      link_token_hash: IntakeLink.hash(IntakeLink.token(id, 1)),
      contacted_at: @now
    }
    |> Intake.contact_changeset()
    |> Repo.insert!()
  end

  defp cleanup!(%{workshop: workshop, people: people, intakes: intakes, fee_ids: fee_ids}) do
    intake_ids = Enum.map(intakes, & &1.id)
    person_ids = Enum.map(people, & &1.id)
    emails = Enum.map(people, & &1.email)

    Repo.delete_all(from(p in IntakePayment, where: p.intake_id in ^intake_ids))
    Repo.delete_all(from(l in IntakeEmailLog, where: l.intake_id in ^intake_ids))
    Repo.delete_all(from(e in IntakeEvent, where: e.intake_id in ^intake_ids))

    Repo.update_all(from(i in Intake, where: i.id in ^intake_ids),
      set: [carried_fee_id: nil, paid_via: nil, paid_at: nil, state: "lapsed"]
    )

    Repo.delete_all(from(f in CarriedFee, where: f.id in ^fee_ids))
    Repo.delete_all(from(i in Intake, where: i.id in ^intake_ids))
    Repo.delete_all(from(w in BeginnersWorkshop, where: w.id == ^workshop.id))
    Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'email'", j.args) in ^emails))
    Repo.delete_all(from(p in UserProfile, where: p.waitlist_id in ^person_ids))
    Repo.delete_all(from(e in WaitlistEntry, where: e.id in ^person_ids))
  end
end
