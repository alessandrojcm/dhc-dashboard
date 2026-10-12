defmodule Dhc.BeginnersWorkshops.IntakePaymentsConcurrencyTest do
  @moduledoc """
  ALE-381: Intake payment races on real connections outside the SQL
  sandbox (`Dhc.ConcurrencyHelpers`), because a sandboxed connection
  serializes everything and cannot show a lock bug. Stripe is stubbed at the
  HTTP seam; the racing Tasks reach the stub through `$callers`.

    * N people pressing Pay for the last seat get exactly one Seat Hold;
      the rest see `full`.
    * The webhook and the success return completing the same payment give
      one transition and one "Place confirmed" email.
    * Every payment command takes its locks top-down (Beginners' Workshop →
      Intake → payment) and writes only inside a transaction.
  """

  use Dhc.DataCase, async: false

  import Dhc.BeginnersWorkshopFixtures
  import Dhc.ConcurrencyHelpers

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeLink,
    IntakePayment,
    LockTrace,
    WorkshopPolicy
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]
  @people 5

  defp pay(token),
    do:
      BeginnersWorkshops.execute({:intake_link, token}, :start_payment, clock: Clock.fixed(@now))

  defp complete(session),
    do:
      BeginnersWorkshops.execute(:stripe, {:complete_payment, session}, clock: Clock.fixed(@now))

  test "N people pressing Pay for the last seat get exactly one hold; the rest see full" do
    committed(1, fn %{workshop: workshop, tokens: tokens} ->
      Stripe.stub_create()

      results =
        hold_lock_then(
          "SELECT id FROM beginners_workshops WHERE id = $1 FOR UPDATE",
          [Ecto.UUID.dump!(workshop.id)],
          Enum.map(tokens, fn token -> fn -> pay(token) end end)
        )

      assert Enum.count(results, &match?({:ok, %{checkout_url: _}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :full})) == @people - 1

      assert [%IntakePayment{status: "open"}] =
               Repo.all(from(p in IntakePayment, where: p.workshop_id == ^workshop.id))
    end)
  end

  test "the webhook and the success return completing one payment give one transition and one email" do
    committed(1, fn %{workshop: workshop, intakes: [intake | _], tokens: [token | _]} ->
      Stripe.stub_create()
      assert {:ok, _} = pay(token)
      row = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))
      session = Stripe.session(row)
      Stripe.stub_retrieve(session)

      results =
        hold_lock_then(
          "SELECT id FROM beginners_workshops WHERE id = $1 FOR UPDATE",
          [Ecto.UUID.dump!(workshop.id)],
          [fn -> complete(session) end, fn -> complete(session["id"]) end]
        )

      assert results |> Enum.map(fn {:ok, %{outcome: o}} -> o end) |> Enum.sort() ==
               [:already_recorded, :paid]

      assert %Intake{state: "paid"} = Repo.reload!(intake)

      assert Repo.aggregate(
               from(l in IntakeEmailLog,
                 where: l.intake_id == ^intake.id and l.occasion == "place_confirmed"
               ),
               :count
             ) == 1

      email = Repo.get!(WaitlistEntry, intake.waitlist_id).email

      assert Repo.aggregate(
               from(j in Oban.Job,
                 where:
                   fragment("?->'data_variables'->>'BUTTON_LABEL'", j.args) == "View my place" and
                     fragment("?->>'email'", j.args) == ^email
               ),
               :count
             ) == 1
    end)
  end

  test "start, complete, release and reap lock top-down and write only inside a transaction" do
    committed(2, fn %{intakes: [first, second | _], tokens: [first_token, second_token | _]} ->
      Stripe.stub_create()

      {_, start_events} = LockTrace.trace(fn -> {:ok, _} = pay(first_token) end)
      row = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^first.id))

      {_, complete_events} =
        LockTrace.trace(fn -> {:ok, %{outcome: :paid}} = complete(Stripe.session(row)) end)

      {:ok, _} = pay(second_token)
      second_row = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^second.id))
      Stripe.stub_expire(Stripe.session(second_row, %{"status" => "open"}))

      {_, reap_events} =
        LockTrace.trace(fn ->
          {:ok, %{released: 1}} =
            BeginnersWorkshops.execute(:system, :reap_holds,
              clock: Clock.fixed(DateTime.add(@now, 30 * 60))
            )
        end)

      for events <- [start_events, complete_events, reap_events] do
        assert LockTrace.upward_locks(events) == []
        assert LockTrace.writes_outside_transaction(events) == []
      end

      assert LockTrace.transactions(start_events) == [
               ~w(beginners_workshops waitlist beginners_workshop_intakes beginners_workshop_carried_fees beginners_workshop_intake_payments),
               ~w(beginners_workshops beginners_workshop_intakes beginners_workshop_intake_payments)
             ]

      assert LockTrace.transactions(complete_events) == [
               ~w(beginners_workshops beginners_workshop_intakes beginners_workshop_intake_payments)
             ]
    end)
  end

  # A workshop with `capacity` seats and `@people` contacted (fast-track)
  # Intakes, committed outside the sandbox and deleted afterwards.
  defp committed(capacity, fun) do
    ctx =
      outside_sandbox(fn ->
        workshop =
          %{
            venue: "Race Hall",
            date: ~D[2026-11-14],
            start_time: ~T[18:30:00],
            capacity: capacity,
            fee_cents: 4000,
            payment_cutoff: ~U[2026-11-11 18:30:00.000000Z],
            contact_from: ~D[2026-10-20],
            payment_window_days: WorkshopPolicy.default_payment_window_days()
          }
          |> BeginnersWorkshop.schedule_changeset()
          |> Repo.insert!()

        people = waiting_people_fixture(@people)

        intakes =
          for person <- people do
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

        %{
          workshop: workshop,
          people: people,
          intakes: intakes,
          tokens: Enum.map(intakes, &IntakeLink.token(&1.id, 1))
        }
      end)

    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    outside_sandbox(fn -> fun.(ctx) end)
  end

  defp cleanup!(%{workshop: workshop, people: people, intakes: intakes}) do
    intake_ids = Enum.map(intakes, & &1.id)
    person_ids = Enum.map(people, & &1.id)
    emails = Enum.map(people, & &1.email)

    Repo.delete_all(from(p in IntakePayment, where: p.intake_id in ^intake_ids))
    Repo.delete_all(from(l in IntakeEmailLog, where: l.intake_id in ^intake_ids))
    Repo.delete_all(from(i in Intake, where: i.id in ^intake_ids))
    Repo.delete_all(from(w in BeginnersWorkshop, where: w.id == ^workshop.id))
    Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'email'", j.args) in ^emails))
    Repo.delete_all(from(p in UserProfile, where: p.waitlist_id in ^person_ids))
    Repo.delete_all(from(e in WaitlistEntry, where: e.id in ^person_ids))
  end
end
