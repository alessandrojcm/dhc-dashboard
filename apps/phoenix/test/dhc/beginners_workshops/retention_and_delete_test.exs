defmodule Dhc.BeginnersWorkshops.RetentionAndDeleteTest do
  @moduledoc """
  ALE-396 (spec stories 119 and 120): the one hard delete through
  `Dhc.BeginnersWorkshops.execute/3` with fixed clocks — `purge_retention`
  (the sweep's pass, at 3 months and not before) and the coordinator's
  `delete_person` (its refusals and the refund-or-forfeit choice). Both
  delete the Waitlist entry, the unclaimed UserProfile and the Guardian,
  anonymise the person's Intakes (queue date kept; an attended Intake
  records the person's Invitation outcome) and keep the Carried Fee row
  with no link to the person.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    CarriedFee,
    Clock,
    Intake,
    IntakePayment,
    IntakeRefund
  }

  alias Dhc.BeginnersWorkshops.Workers.RefundWorker
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.{WaitlistEntry, WaitlistGuardian}

  @now ~U[2026-10-22 12:00:00.000000Z]
  @removed_at ~U[2026-07-22 12:00:00Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp execute(actor, command, at \\ @now),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(at))

  defp delete_person(c, person, attrs \\ %{}),
    do: execute({:staff, c}, {:delete_person, person.id, attrs})

  defp removed_person!(removed_at \\ @removed_at) do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    profile = profile_of(person)

    Repo.insert!(%WaitlistGuardian{
      profile_id: profile.id,
      first_name: "Gail",
      last_name: "Guardian",
      phone_number: "+353870000000"
    })

    person
    |> Ecto.Changeset.change(status: "removed", removed_at: removed_at)
    |> Repo.update!()
  end

  defp force_standing!(person, status) do
    person
    |> Ecto.Changeset.change(status: status, removed_at: nil)
    |> Repo.update!()
  end

  defp profile_of(person),
    do: Repo.one(from(p in UserProfile, where: p.waitlist_id == ^person.id))

  defp guardians_of(profile),
    do: Repo.all(from(g in WaitlistGuardian, where: g.profile_id == ^profile.id))

  defp gone?(person, profile) do
    Repo.get(WaitlistEntry, person.id) == nil and Repo.get(UserProfile, profile.id) == nil and
      guardians_of(profile) == []
  end

  defp import_fee!(person) do
    assert {:ok, %{outcome: :created, id: id}} =
             execute(:system, {:import_carried_fee, person.id, "Paid 2025"})

    Repo.get!(CarriedFee, id)
  end

  defp token(intake),
    do: Dhc.BeginnersWorkshops.IntakeLink.token(intake.id, intake.link_generation)

  # A waiting person whose Stripe-paid Intake was deferred: a `held`
  # deferral Carried Fee on that payment.
  defp deferred_holder!(c) do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    workshop = scheduled_fixture(c, %{"contact_from" => "2026-10-20", "capacity" => 1})

    assert {:ok, %{state: "contacted"}} =
             execute({:staff, c}, {:fast_track, workshop.id, {:waitlist_entry, person.id}})

    intake = Repo.one!(from(i in Intake, where: i.waitlist_id == ^person.id))
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token(intake)}, :start_payment)
    payment = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))

    assert {:ok, %{outcome: :paid}} =
             execute(:stripe, {:complete_payment, Stripe.session(payment)})

    assert {:ok, %{state: "deferred"}} =
             execute({:staff, c}, {:defer, workshop.id, intake.id, %{}})

    {Repo.reload!(person), Repo.reload!(intake), Repo.reload!(payment)}
  end

  describe "purge_retention" do
    test "hard-deletes a person removed for more than 3 months, and not before" do
      person = removed_person!()
      profile = profile_of(person)
      three_months = ~U[2026-10-22 12:00:00.000000Z]

      # Exactly 3 months after removal they may still be restored.
      assert %{purged: 0} = BeginnersWorkshops.run_due_passes(clock: Clock.fixed(three_months))

      assert {:ok, %{outcome: :not_due}} =
               execute(:system, {:purge_retention, person.id}, three_months)

      assert Repo.get(WaitlistEntry, person.id)
      assert [_guardian] = guardians_of(profile)

      later = DateTime.add(three_months, 1, :second)

      assert %{purged: 1, failed: 0} =
               BeginnersWorkshops.run_due_passes(clock: Clock.fixed(later))

      assert gone?(person, profile)

      # Running it again finds nobody.
      assert %{purged: 0} = BeginnersWorkshops.run_due_passes(clock: Clock.fixed(later))
    end

    test "leaves waiting people and people removed within retention alone" do
      waiting = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      recent = removed_person!(~U[2026-09-01 12:00:00Z])

      assert %{purged: 0} = BeginnersWorkshops.run_due_passes(clock: Clock.fixed(@now))
      assert {:ok, %{outcome: :not_due}} = execute(:system, {:purge_retention, waiting.id})
      assert Repo.get(WaitlistEntry, waiting.id)
      assert Repo.get(WaitlistEntry, recent.id)
    end

    test "forfeits a held Carried Fee and keeps its row with no link to the person" do
      person = removed_person!()
      fee = import_fee!(person)

      assert {:ok, %{outcome: :purged, carried_fee: %{status: "forfeited"}}} =
               execute(:system, {:purge_retention, person.id}, ~U[2026-10-23 12:00:00.000000Z])

      assert %CarriedFee{status: "forfeited", waitlist_id: nil, imported_paid_text: "Paid 2025"} =
               Repo.reload!(fee)
    end

    test "waits while a removed person's Intake is still open", %{coordinator: c} do
      workshop = scheduled_fixture(c)
      person = removed_person!()
      {intake, _token} = intake_fixture!(workshop.id, person)

      assert {:ok, %{outcome: :not_due}} = execute(:system, {:purge_retention, person.id})
      assert Repo.get(WaitlistEntry, person.id)
      assert %Intake{waitlist_id: id} = Repo.reload!(intake)
      assert id == person.id
    end

    test "is the system's alone", %{coordinator: c} do
      person = removed_person!()
      assert {:error, :forbidden} = execute({:staff, c}, {:purge_retention, person.id})
    end
  end

  describe "anonymisation" do
    test "every Intake loses its person and keeps its queue date; an attended one records the Invitation outcome",
         %{coordinator: c} do
      finished = scheduled_fixture(c)
      earlier = scheduled_fixture(c, %{"date" => "2026-11-21"})
      person = removed_person!()
      profile = profile_of(person)

      {declined, _} = intake_fixture!(earlier.id, person)
      force_intake_state!(declined.id, "declined")
      {attended, _} = intake_fixture!(finished.id, person)
      force_intake_state!(attended.id, "attended")
      force_status!(finished.id, "finalised")

      assert {:ok, %{outcome: :deleted, anonymised_intakes: 2}} = delete_person(c, person)
      assert gone?(person, profile)

      assert %Intake{
               waitlist_id: nil,
               state: "attended",
               invitation_outcome: "not_invited",
               anonymised_at: at,
               queue_date: queue_date
             } = Repo.reload!(attended)

      assert at == @now
      assert queue_date == attended.queue_date

      assert %Intake{waitlist_id: nil, state: "declined", invitation_outcome: nil} =
               anonymised = Repo.reload!(declined)

      assert anonymised.queue_date == declined.queue_date
      assert anonymised.anonymised_at == @now
    end

    test "an anonymised attendee's correction stays refused once they had been invited",
         %{coordinator: c} do
      workshop = scheduled_fixture(c)
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      {intake, _} = intake_fixture!(workshop.id, person)
      force_intake_state!(intake.id, "attended")
      force_status!(workshop.id, "finalised")

      # The outcome an anonymised Intake keeps (as if they had been invited).
      Repo.update_all(from(i in Intake, where: i.id == ^intake.id),
        set: [waitlist_id: nil, anonymised_at: @now, invitation_outcome: "invited"]
      )

      assert {:error, :already_invited} =
               execute(
                 {:staff, c},
                 {:correct_attendance, workshop.id, intake.id, %{"to" => "no_show"}}
               )
    end
  end

  describe "delete_person" do
    test "deletes a waiting person at any time", %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      profile = profile_of(person)

      assert {:ok, %{waitlist_id: id, outcome: :deleted, carried_fee: nil}} =
               delete_person(c, person)

      assert id == person.id
      assert gone?(person, profile)
      assert {:error, :person_not_found} = delete_person(c, person)
    end

    test "is refused with an open Intake and for invited or joined people", %{coordinator: c} do
      workshop = scheduled_fixture(c)
      contacted = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      intake_fixture!(workshop.id, contacted)
      assert {:error, :open_intake} = delete_person(c, contacted)
      assert Repo.get(WaitlistEntry, contacted.id)

      for status <- ~w(invited joined) do
        person = waiting_person_fixture(~U[2025-01-01 12:00:00Z]) |> force_standing!(status)
        assert {:error, :not_deletable} = delete_person(c, person)
        assert Repo.get(WaitlistEntry, person.id)
      end

      assert {:error, :person_not_found} =
               execute({:staff, c}, {:delete_person, Ecto.UUID.generate(), %{}})

      assert {:error, :person_not_found} = execute({:staff, c}, {:delete_person, "nope", %{}})
    end

    test "never deletes a claimed profile", %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      principal = Dhc.AuthFixtures.principal_fixture()

      Repo.update_all(from(p in UserProfile, where: p.waitlist_id == ^person.id),
        set: [principal_id: principal.id]
      )

      assert {:error, :not_deletable} = delete_person(c, person)
      assert Repo.get(WaitlistEntry, person.id)
    end

    test "needs the beginners.waitlist.manage capability" do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      assert {:error, :forbidden} = delete_person(staff_fixture("member"), person)
      assert Repo.get(WaitlistEntry, person.id)
    end

    test "a Carried Fee needs the refund-or-forfeit choice first; forfeit keeps the row unlinked",
         %{coordinator: c} do
      person = removed_person!(~U[2026-10-01 12:00:00Z])
      fee = import_fee!(person)

      assert {:error, :refund_choice_required} = delete_person(c, person)
      assert {:error, :invalid_refund_choice} = delete_person(c, person, %{"refund" => "yes"})
      assert %CarriedFee{status: "held"} = Repo.reload!(fee)

      assert {:ok, %{outcome: :deleted, carried_fee: %{status: "forfeited"}}} =
               delete_person(c, person, %{"refund" => false})

      assert %CarriedFee{status: "forfeited", waitlist_id: nil} = Repo.reload!(fee)
      refute Repo.get(WaitlistEntry, person.id)
    end

    test "a refund is requested against the original payment and its history survives the person",
         %{coordinator: c} do
      {person, deferred, payment} = deferred_holder!(c)
      fee = Repo.one!(from(f in CarriedFee, where: f.waitlist_id == ^person.id))

      assert {:ok,
              %{outcome: :deleted, anonymised_intakes: 1, carried_fee: %{status: "refunded"}}} =
               delete_person(c, person, %{"refund" => true})

      assert %CarriedFee{status: "refunded", waitlist_id: nil} = Repo.reload!(fee)
      assert %Intake{waitlist_id: nil, state: "deferred"} = Repo.reload!(deferred)

      assert [%IntakeRefund{reason: "deleted", amount_cents: 4000, status: "pending"} = refund] =
               Repo.all(from(r in IntakeRefund, where: r.carried_fee_id == ^fee.id))

      assert refund.payment_id == payment.id
      assert_enqueued(worker: RefundWorker, args: %{"refund_id" => refund.id})

      # The refund still goes through once the person is gone.
      Stripe.stub_refund_create("succeeded")
      assert {:ok, %{outcome: :completed}} = execute(:system, {:submit_refund, refund.id})
      assert %IntakeRefund{status: "completed"} = Repo.reload!(refund)
    end

    test "an unlinked imported fee can only be forfeited", %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      import_fee!(person)

      assert {:error, :payment_not_linked} = delete_person(c, person, %{"refund" => true})
      assert Repo.get(WaitlistEntry, person.id)
    end
  end
end
