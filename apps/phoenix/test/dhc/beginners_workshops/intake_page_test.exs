defmodule Dhc.BeginnersWorkshops.IntakePageTest do
  @moduledoc """
  ALE-381: the Intake page read model (`Dhc.BeginnersWorkshops.intake_page/2`)
  in every safe-view state — `pay`, `payment_in_progress`, `full`, `paid`
  and `closed` — and that it never carries ids or Stripe objects.
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, IntakePayment}
  alias Dhc.Repo

  @now ~U[2026-10-22 12:00:00.000000Z]
  @cutoff ~U[2026-11-11 18:30:00.000000Z]

  setup do
    coordinator = staff_fixture("beginners_coordinator")
    {workshop, intakes} = contacted_fixture(coordinator, 2)
    Stripe.stub_create()
    %{workshop: workshop, intakes: intakes, coordinator: coordinator}
  end

  defp page(token, at \\ @now, opts \\ []),
    do: BeginnersWorkshops.intake_page(token, Keyword.put(opts, :clock, Clock.fixed(at)))

  defp pay(token, at \\ @now),
    do: BeginnersWorkshops.execute({:intake_link, token}, :start_payment, clock: Clock.fixed(at))

  defp hold(intake), do: Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))

  test "pay: the person's first name, the workshop, the fee and one action", %{
    intakes: [{_, token} | _]
  } do
    assert {:ok, page} = page(token)

    assert %{
             state: :pay,
             action: :pay,
             closed_reason: nil,
             fee_cents: 4000,
             workshop: %{
               date: ~D[2026-11-14],
               start_time: ~T[18:30:00],
               venue: "St. Andrew's Hall"
             }
           } = page

    assert page.first_name =~ "Person"

    assert Map.keys(page) |> Enum.sort() ==
             ~w(action closed_reason fee_cents first_name state workshop)a
  end

  test "pay with a live hold continues that checkout", %{intakes: [{_, token} | _]} do
    assert {:ok, _} = pay(token)
    assert {:ok, %{state: :pay, action: :continue_payment}} = page(token)
  end

  test "payment_in_progress: back from the hold's checkout, or the hold ran out before Stripe ended it",
       %{intakes: [{intake, token} | _]} do
    assert {:ok, _} = pay(token)
    session_id = Stripe.session_id(hold(intake))

    assert {:ok, %{state: :payment_in_progress, action: :check_again}} =
             page(token, @now, returned_session: session_id)

    assert {:ok, %{state: :pay}} = page(token, @now, returned_session: "cs_someone_else")

    assert {:ok, %{state: :payment_in_progress}} = page(token, DateTime.add(@now, 30 * 60))
  end

  test "full: every seat is paid or held",
       %{intakes: [{_, first}, {_, second}], workshop: w, coordinator: coordinator} do
    {:ok, _} =
      BeginnersWorkshops.execute(
        {:staff, coordinator},
        {:update_workshop, w.id, %{"capacity" => 1}},
        clock: Clock.fixed(@now)
      )

    assert {:ok, _} = pay(first)
    assert {:ok, %{state: :full, action: :check_again, first_name: name}} = page(second)
    assert is_binary(name)
  end

  test "paid", %{intakes: [{intake, token} | _]} do
    assert {:ok, _} = pay(token)

    assert {:ok, _} =
             BeginnersWorkshops.execute(
               :stripe,
               {:complete_payment, Stripe.session(hold(intake))},
               clock: Clock.fixed(@now)
             )

    assert {:ok, %{state: :paid, action: :none, fee_cents: 4000}} = page(token)
  end

  test "closed: payment closes at the cutoff; a closed Intake's link is no longer active",
       %{intakes: [{_, first}, {second, second_token}]} do
    assert {:ok, %{state: :closed, closed_reason: :payment_closed, action: :none, workshop: %{}}} =
             page(first, @cutoff)

    force_intake_state!(second.id, "declined")

    assert {:ok,
            %{
              state: :closed,
              closed_reason: :inactive,
              first_name: nil,
              workshop: nil,
              fee_cents: nil
            }} = page(second_token)
  end

  test "an unknown link is not found" do
    assert {:error, :not_found} = page("unknown")
  end
end
