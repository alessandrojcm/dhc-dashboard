defmodule Dhc.BeginnersWorkshops.BatchProposalTest do
  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BatchProposal, Clock}

  setup do
    coordinator = staff_fixture("beginners_coordinator")
    workshop = scheduled_fixture(coordinator)
    other = scheduled_fixture(coordinator, %{"date" => "2026-11-21"})
    %{workshop: workshop, other: other}
  end

  for state <-
        ~w(contacted paid declined lapsed returned deferred withdrawn no_show attended cancelled_refunded) do
    @state state
    test "a #{@state} Intake excludes this workshop only, unless it is still open",
         %{workshop: workshop, other: other} do
      [previous, next] = waiting_people_fixture(2)
      {intake, _token} = intake_fixture!(workshop.id, previous)
      force_intake_state!(intake.id, @state)

      assert Enum.map(BatchProposal.people(workshop.id, 1), & &1.waitlist_id) == [next.id]

      expected = if @state in ~w(contacted paid), do: [next.id], else: [previous.id, next.id]
      assert Enum.map(BatchProposal.people(other.id, 2), & &1.waitlist_id) == expected
    end
  end

  test "an Intake lapsed by the cutoff stays excluded after the person returns to waiting",
       %{workshop: workshop, other: other} do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    {_intake, _token} = intake_fixture!(workshop.id, person)
    cutoff = ~U[2026-11-11 18:30:00Z]

    assert {:ok, %{lapsed: 1}} =
             BeginnersWorkshops.execute(:system, {:pass_payment_cutoff, workshop.id},
               clock: Clock.fixed(cutoff)
             )

    assert {:ok, _} = Dhc.Waitlist.restore(person.id, now: DateTime.add(cutoff, 60))
    assert BatchProposal.people(workshop.id, 5) == []
    assert [%{waitlist_id: id}] = BatchProposal.people(other.id, 5)
    assert id == person.id
  end

  test "a zero-size proposal is empty", %{workshop: workshop} do
    waiting_people_fixture(1)
    assert BatchProposal.people(workshop.id, 0) == []
  end
end
