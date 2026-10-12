defmodule Dhc.BeginnersWorkshops.PolicyParityTest do
  @moduledoc """
  ALE-402: each read model builds the very facts the boundary decides by.
  Over a fixture matrix of Intake states, standings and Carried Fee
  situations, `WorkshopConsole`'s `IntakePolicy` facts equal the boundary's
  locked read (`Commands.locked_intake_facts/3`), and `CarriedFeeView`'s
  `CarriedFeePolicy` facts equal `Commands.locked_carried_fee_facts/2`.
  ALE-417: `PeopleView`'s `PersonPolicy` facts equal
  `Commands.locked_person_facts/2`, and what it offers (and whether it asks
  for the refund-or-forfeit choice) is what the person commands do.
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops.{
    CarriedFee,
    CarriedFeePolicy,
    CarriedFeeView,
    Clock,
    Commands,
    Intake,
    IntakePolicy,
    IntakePayment,
    IntakeRefund,
    PeopleView,
    PersonPolicy,
    WorkshopConsole
  }

  alias Dhc.Repo

  @now ~U[2026-10-22 12:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp at(days_before), do: DateTime.add(@now, -days_before * 86_400, :second)

  defp fee!(person, status, opts \\ []) do
    linked = Keyword.get(opts, :linked, true)

    Repo.insert!(%CarriedFee{
      waitlist_id: person.id,
      status: status,
      origin: "import",
      imported_paid_text: "Paid",
      stripe_payment_intent_id: if(linked, do: "pi_#{System.unique_integer([:positive])}"),
      amount_cents: if(linked, do: 3500),
      applied_intake_id: Keyword.get(opts, :applied_intake_id),
      status_changed_at: Keyword.get(opts, :at, at(30))
    })
  end

  defp refund!(fee, status, opts \\ []) do
    %{
      carried_fee_id: fee.id,
      follows_refund_id: Keyword.get(opts, :follows),
      reason: "carried_fee_refunded",
      amount_cents: 3500,
      currency: "eur",
      stripe_payment_intent_id: fee.stripe_payment_intent_id,
      requested_at: at(10)
    }
    |> IntakeRefund.request_changeset()
    |> Ecto.Changeset.change(status: status, failed_at: if(status == "failed", do: at(9)))
    |> Repo.insert!()
  end

  defp person!(status \\ "waiting", registered_at \\ ~U[2025-01-01 12:00:00Z]),
    do: waiting_person_fixture(registered_at, status: status)

  defp removed!(days_ago) do
    person = person!()

    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} = Dhc.Waitlist.change_standing(person.id, "removed", now: at(days_ago))
      end)

    Repo.reload!(person)
  end

  defp intake!(workshop, person, state) do
    {intake, _token} = intake_fixture!(workshop.id, person)
    if state != "contacted", do: force_intake_state!(intake.id, state)
    Repo.reload!(intake)
  end

  defp anonymise!(intake, outcome) do
    intake
    |> Ecto.Changeset.change(waitlist_id: nil, anonymised_at: at(1), invitation_outcome: outcome)
    |> Repo.update!()
  end

  defp cancelled_with_fee_refund!(workshop, person) do
    intake = workshop |> intake!(person, "contacted") |> force_carried_fee_paid!()

    Repo.get!(CarriedFee, intake.carried_fee_id)
    |> Ecto.Changeset.change(
      status: "refunded",
      applied_intake_id: nil,
      status_changed_at: at(60)
    )
    |> Repo.update!()

    intake |> Ecto.Changeset.change(state: "cancelled_refunded") |> Repo.update!()
  end

  # Every situation the rules tell apart, as `{label, person | nil, intake}`.
  defp matrix(workshop) do
    plain = person!()

    unlinked = person!()
    fee!(unlinked, "held", linked: false)

    linked = person!()
    fee!(linked, "held")

    recent = removed!(20)
    fee!(recent, "held")

    long_ago = removed!(200)
    fee!(long_ago, "held")

    refunded = person!()
    fee!(refunded, "refunded")

    # A Carried-Fee-paid Intake cancelled with refund, and a newer live fee
    # the person has held since.
    again = person!()
    cancelled_paid_by_fee = cancelled_with_fee_refund!(workshop, again)
    fee!(again, "held", at: at(5))

    failed = person!()
    failed |> fee!("held") |> refund!("failed")

    followed = person!()
    followed_fee = fee!(followed, "held")
    first = refund!(followed_fee, "failed")
    refund!(followed_fee, "completed", follows: first.id)

    still_refunded = person!()
    still_refunded |> fee!("refunded") |> refund!("failed")

    spent = person!("attended")
    fee!(spent, "spent")

    applied = person!()
    paid_by_fee = intake!(workshop, applied, "contacted") |> force_carried_fee_paid!()

    attended = person!("attended")
    invited = person!("invited")
    anonymised = person!("attended")
    anonymised_not_invited = person!("attended")

    [
      {"contacted, no fee", plain, intake!(workshop, plain, "contacted")},
      {"contacted, unlinked held fee", unlinked, intake!(workshop, unlinked, "contacted")},
      {"contacted, linked held fee", linked, intake!(workshop, linked, "contacted")},
      {"declined, removed recently, held fee", recent, intake!(workshop, recent, "declined")},
      {"declined, removed long ago, held fee", long_ago, intake!(workshop, long_ago, "declined")},
      {"cancelled, latest fee refunded", refunded,
       intake!(workshop, refunded, "cancelled_refunded")},
      {"cancelled, paid by a refunded fee, held another since", again, cancelled_paid_by_fee},
      {"contacted, failed refund", failed, intake!(workshop, failed, "contacted")},
      {"contacted, followed-up refund", followed, intake!(workshop, followed, "contacted")},
      {"withdrawn, refund failed, fee still refunded", still_refunded,
       intake!(workshop, still_refunded, "withdrawn")},
      {"attended, spent fee", spent, intake!(workshop, spent, "attended")},
      {"paid by Carried Fee", applied, paid_by_fee},
      {"paid via Stripe", nil, intake!(workshop, person!(), "paid")},
      {"attended", attended, intake!(workshop, attended, "attended")},
      {"no show", nil, intake!(workshop, person!("removed"), "no_show")},
      {"attended, invited", invited, intake!(workshop, invited, "attended")},
      {"anonymised attendee, invited", nil,
       workshop |> intake!(anonymised, "attended") |> anonymise!("invited")},
      {"anonymised attendee, not invited", nil,
       workshop |> intake!(anonymised_not_invited, "attended") |> anonymise!("not_invited")}
    ]
  end

  for status <- ["scheduled", "finalised", "cancelled"] do
    @status status

    test "the console builds the locked read's IntakePolicy facts (#{status} workshop)",
         %{coordinator: c} do
      workshop = scheduled_fixture(c)
      cases = matrix(workshop)
      if @status != "scheduled", do: force_status!(workshop.id, @status)

      console = WorkshopConsole.intake_facts(workshop.id, Clock.fixed(@now))
      {:ok, view} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
      rows = view.roster |> Map.values() |> List.flatten() |> Map.new(&{&1.id, &1})

      for {label, _person, %Intake{id: id}} <- cases do
        assert {:ok, %IntakePolicy{} = locked} =
                 Commands.locked_intake_facts(workshop.id, id, Clock.fixed(@now))

        assert console[id] == locked, label
        assert rows[id].available_commands == IntakePolicy.available_commands(locked), label
      end
    end
  end

  test "CarriedFeeView builds the locked read's CarriedFeePolicy facts", %{coordinator: c} do
    workshop = scheduled_fixture(c)

    people =
      for {_label, %{} = person, _intake} <- matrix(workshop), uniq: true, do: person

    shown =
      for person <- people,
          {:ok, facts} <- [CarriedFeeView.facts(person.id, @now)] do
        assert {:ok, %CarriedFeePolicy{} = locked} =
                 Commands.locked_carried_fee_facts(person.id, Clock.fixed(@now))

        assert facts == locked, inspect(person.id)

        assert {:ok, %{available: available}} = CarriedFeeView.show(person.id, @now)
        assert available == CarriedFeePolicy.available(locked)
        facts
      end

    # The matrix reaches every Carried Fee status the view shows and every
    # refund state.
    assert Enum.map(shown, & &1.status) |> Enum.uniq() |> Enum.sort() ==
             ~w(applied held refunded spent)

    assert Enum.map(shown, & &1.refund) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort([nil, :failed, :not_failed])
  end

  # The Waitlist tab's people: everyone the console matrix names, and the
  # situations only a person without an open Intake reaches.
  defp people(workshop, except \\ []) do
    from_matrix =
      for {label, _person, %Intake{waitlist_id: id}} <- matrix(workshop),
          id != nil and label not in except,
          do: id

    plain = person!()

    held = person!()
    fee!(held, "held")

    unlinked = person!()
    fee!(unlinked, "held", linked: false)

    failed = person!()
    failed |> fee!("held") |> refund!("failed")

    removed = removed!(20)
    removed_with_fee = removed!(20)
    fee!(removed_with_fee, "held")
    long_removed = removed!(200)

    claimed = person!()
    principal = Dhc.AuthFixtures.principal_fixture()

    Repo.update_all(
      from(p in Dhc.UserProfiles.UserProfile, where: p.waitlist_id == ^claimed.id),
      set: [principal_id: principal.id]
    )

    stripe = person!()
    stripe_paid = intake!(workshop, stripe, "paid")

    Repo.insert!(%IntakePayment{
      workshop_id: workshop.id,
      intake_id: stripe_paid.id,
      status: "paid",
      amount_cents: 4000,
      expires_at: @now,
      stripe_checkout_session_id: "cs_#{stripe_paid.id}",
      stripe_payment_intent_id: "pi_#{stripe_paid.id}",
      amount_received_cents: 4000,
      currency_received: "eur",
      paid_at: @now
    })

    joined = person!("joined")

    Enum.uniq(
      from_matrix ++
        Enum.map(
          [
            plain,
            held,
            unlinked,
            failed,
            removed,
            removed_with_fee,
            long_removed,
            claimed,
            stripe,
            joined
          ],
          & &1.id
        )
    )
  end

  test "PeopleView builds the locked read's PersonPolicy facts", %{coordinator: c} do
    workshop = scheduled_fixture(c)
    ids = people(workshop)

    facts = PeopleView.facts(ids, @now)
    listed = PeopleView.list(ids, @now)

    for id <- ids do
      assert {:ok, %PersonPolicy{} = locked} =
               Commands.locked_person_facts(id, Clock.fixed(@now))

      assert facts[id] == locked, id
      assert listed[id].available_commands == PersonPolicy.available_commands(locked), id
    end

    # The fixtures offer and withhold every command, and both kinds of money.
    offered = listed |> Map.values() |> Enum.flat_map(& &1.available_commands)
    assert offered |> Enum.uniq() |> Enum.sort() == Enum.sort(PersonPolicy.commands())

    for command <- PersonPolicy.commands(),
        do: assert(Enum.any?(Map.values(listed), &(command not in &1.available_commands)))

    sources =
      for %{refund_choice: %{source: source}} <- Map.values(listed), uniq: true, do: source

    assert Enum.sort(sources) == [:carried_fee, :payment]
  end

  # Runs one person command and rolls everything it wrote back.
  defp dry_run(c, command, id, attrs) do
    {:error, {:dry_run, result}} =
      Repo.transaction(fn ->
        result =
          Dhc.BeginnersWorkshops.execute({:staff, c}, {command, id, attrs},
            clock: Clock.fixed(@now)
          )

        Repo.rollback({:dry_run, result})
      end)

    result
  end

  test "what PeopleView offers is what the person commands do", %{coordinator: c} do
    workshop = scheduled_fixture(c)
    # A held fee whose follow-up refund completed is a facts-only fixture:
    # a completed refund leaves the fee `refunded`, so no command reaches it.
    ids = people(workshop, ["contacted, followed-up refund"])
    listed = PeopleView.list(ids, @now)
    facts = PeopleView.facts(ids, @now)

    for id <- ids, command <- PersonPolicy.commands() do
      person = listed[id]
      label = "#{command} #{id}"
      choice = if person.refund_choice, do: %{"refund" => false}, else: %{}

      result = dry_run(c, command, id, choice)
      label = "#{label}: #{inspect(result)}"

      if command in person.available_commands do
        assert match?({:ok, %{outcome: outcome}} when outcome in [:done, :deleted], result),
               label

        if person.refund_choice != nil and command in [:withdraw, :delete_person],
          do: assert(dry_run(c, command, id, %{}) == {:error, :refund_choice_required}, label)
      else
        # A refund awaiting its follow-up is offered as the follow-ups instead.
        withheld = command == :refund_carried_fee and facts[id].carried_fee.refund == :failed

        refute not withheld and
                 match?({:ok, %{outcome: outcome}} when outcome in [:done, :deleted], result),
               label
      end
    end
  end

  describe "where the console used to disagree with the boundary" do
    defp run(c, name, workshop, intake, attrs \\ %{}) do
      Dhc.BeginnersWorkshops.execute({:staff, c}, {name, workshop.id, intake.id, attrs},
        clock: Clock.fixed(@now)
      )
    end

    defp offered(workshop, intake) do
      {:ok, view} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
      row = view.roster |> Map.values() |> List.flatten() |> Enum.find(&(&1.id == intake.id))
      row.available_commands
    end

    test "an unlinked held fee is not offered a refund the boundary refuses", %{coordinator: c} do
      workshop = scheduled_fixture(c)
      person = person!()
      fee!(person, "held", linked: false)
      intake = intake!(workshop, person, "contacted")

      refute :refund_carried_fee in offered(workshop, intake)
      assert {:error, :payment_not_linked} = run(c, :refund_carried_fee, workshop, intake)
    end

    test "an Intake paid by a refunded fee offers refunding the person's newer live fee",
         %{coordinator: c} do
      workshop = scheduled_fixture(c)
      person = person!()
      intake = cancelled_with_fee_refund!(workshop, person)
      fee!(person, "held", at: at(5))

      assert :refund_carried_fee in offered(workshop, intake)
      assert {:ok, %{outcome: :done}} = run(c, :refund_carried_fee, workshop, intake)
    end

    test "an anonymised invited attendee is not offered a correction", %{coordinator: c} do
      workshop = scheduled_fixture(c)
      intake = workshop |> intake!(person!("attended"), "attended") |> anonymise!("invited")
      force_status!(workshop.id, "finalised")

      refute :correct_attendance in offered(workshop, intake)

      assert {:error, :already_invited} =
               run(c, :correct_attendance, workshop, intake, %{"to" => "no_show"})
    end
  end
end
