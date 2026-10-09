defmodule Dhc.BeginnersWorkshops.IntakePaymentsTest do
  @moduledoc """
  ALE-381: seat-capped Intake payment through `Dhc.BeginnersWorkshops.execute/3`
  with a fixed clock and Stripe stubbed at the HTTP seam
  (`Dhc.BeginnersIntakeStripe`) — `start_payment` (Seat Holds, the cap,
  the cutoff, reuse, Stripe failures), `complete_payment` (paid, idempotent,
  policy failures), `release_payment`, the `reap_holds` pass, the capacity
  rule, the transition table and the webhook routes.

  The workshop under test: Saturday 14 November 2026 at 18:30 Dublin,
  Payment Cutoff Wednesday 11 November 18:30 UTC, contacted at 10:00 Dublin
  on Tuesday 20 October (Batch window until 27 October 23:59).
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, Commands, Intake, IntakeEmailLog, IntakePayment}
  alias Dhc.Email.Worker
  alias Dhc.Repo
  alias Dhc.StripeWebhooks

  # Two days into Batch 1's window.
  @now ~U[2026-10-22 12:00:00.000000Z]
  @hold_ends ~U[2026-10-22 12:30:00.000000Z]
  @cutoff ~U[2026-11-11 18:30:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp at(at \\ @now), do: Clock.fixed(at)

  defp pay(token, at \\ @now),
    do: BeginnersWorkshops.execute({:intake_link, token}, :start_payment, clock: at(at))

  defp complete(session, at \\ @now),
    do: BeginnersWorkshops.execute(:stripe, {:complete_payment, session}, clock: at(at))

  defp release(session, at \\ @now),
    do: BeginnersWorkshops.execute(:stripe, {:release_payment, session}, clock: at(at))

  defp reap(at),
    do: BeginnersWorkshops.execute(:system, :reap_holds, clock: at(at))

  defp payments(intake),
    do:
      Repo.all(from(p in IntakePayment, where: p.intake_id == ^intake.id, order_by: p.created_at))

  defp payment!(intake), do: intake |> payments() |> List.last()

  defp seats(workshop) do
    %{upcoming: rows} = BeginnersWorkshops.list_workshops(clock: at())
    Enum.find(rows, &(&1.id == workshop.id)).seats
  end

  defp confirmed_jobs,
    do:
      Enum.filter(
        all_enqueued(worker: Worker),
        &(&1.args["data_variables"]["BUTTON_LABEL"] == "View my place")
      )

  defp paid_through_stripe(token, intake) do
    Stripe.stub_create()
    assert {:ok, _} = pay(token)
    row = payment!(intake)
    assert {:ok, %{outcome: :paid}} = complete(Stripe.session(row))
    row
  end

  describe "start_payment" do
    test "takes a Seat Hold with the fee frozen and 30 minutes to run, then creates the Checkout Session",
         %{coordinator: coordinator} do
      {workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()

      assert {:ok, %{checkout_url: url}} = pay(token)

      assert [%IntakePayment{status: "open", amount_cents: 4000, currency: "eur"} = row] =
               payments(intake)

      assert row.expires_at == @hold_ends
      assert row.workshop_id == workshop.id
      assert row.stripe_checkout_session_id == Stripe.session_id(row)
      assert url == Stripe.checkout_url(Stripe.session_id(row))

      assert_received {:checkout_created, form, key}
      assert key == "beginners-intake-payment:#{row.id}"

      link = Dhc.BeginnersWorkshops.IntakeLink.url(token)

      assert %{
               "mode" => "payment",
               "line_items[0][quantity]" => "1",
               "line_items[0][price_data][currency]" => "eur",
               "line_items[0][price_data][unit_amount]" => "4000",
               "payment_method_types[0]" => "card",
               "payment_method_types[1]" => "revolut_pay",
               "payment_method_types[2]" => "link",
               "metadata[payment_id]" => payment_id,
               "success_url" => success_url,
               "cancel_url" => ^link
             } = form

      assert payment_id == row.id
      assert success_url == link <> "?session_id={CHECKOUT_SESSION_ID}"
      assert form["customer_email"] =~ "@waitlist.example.com"
      # The session outlives the hold by Stripe's latency grace; the reaper
      # expires it when the hold runs out.
      assert form["expires_at"] == to_string(DateTime.to_unix(@hold_ends) + 60)
      refute Map.has_key?(form, "customer")

      assert %{paid: 0, holds: 1} = seats(workshop)
    end

    test "pressing Pay again while the hold is live reuses its session", %{
      coordinator: coordinator
    } do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()

      assert {:ok, %{checkout_url: url}} = pay(token)
      assert_received {:checkout_created, _form, _key}

      assert {:ok, %{checkout_url: ^url}} = pay(token, DateTime.add(@now, 29 * 60))
      refute_received {:checkout_created, _form, _key}
      assert [%IntakePayment{status: "open"}] = payments(intake)
    end

    test "when every seat is paid or held the next person sees full; a released hold frees the seat",
         %{coordinator: coordinator} do
      {workshop, [{first, first_token}, {second, second_token}, {_third, third_token}]} =
        contacted_fixture(coordinator, 3)

      Stripe.stub_create()
      paid_through_stripe(first_token, first)
      assert {:ok, _} = pay(second_token)

      # Capacity 3: one paid, one held, one free.
      assert {:ok, _} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:update_workshop, workshop.id, %{"capacity" => 2}},
                 clock: at()
               )

      assert {:error, :full} = pay(third_token)
      assert %{paid: 1, holds: 1, free: 0} = seats(workshop)

      held = payment!(second)

      assert {:ok, %{outcome: :released}} =
               release(Stripe.session(held, %{"status" => "expired"}))

      assert %IntakePayment{status: "released"} = Repo.reload!(held)

      assert {:ok, %{checkout_url: _}} = pay(third_token)
    end

    test "is refused after the Payment Cutoff; a person who missed their window can still pay before it",
         %{coordinator: coordinator} do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()

      assert {:error, :after_cutoff} = pay(token, @cutoff)
      assert payments(intake) == []

      # The window ended on 27 October; seats remain until the cutoff.
      assert {:ok, %{checkout_url: _}} = pay(token, DateTime.add(@cutoff, -60))
    end

    test "an unknown link is not found; a paid Intake is already paid; only the link may start a payment",
         %{coordinator: coordinator} do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)

      assert {:error, :not_found} = pay("not-a-real-token")

      assert {:error, :forbidden} =
               BeginnersWorkshops.execute({:staff, coordinator}, :start_payment)

      assert {:error, :forbidden} = BeginnersWorkshops.execute(:stripe, :start_payment)

      assert {:error, :forbidden} =
               BeginnersWorkshops.execute({:intake_link, token}, {:complete_payment, "cs_1"})

      force_intake_state!(intake.id, "paid")
      assert {:error, :already_paid} = pay(token)
      force_intake_state!(intake.id, "declined")
      assert {:error, :intake_closed} = pay(token)
    end

    test "a hold whose 30 minutes ran out is in progress until Stripe ends it",
         %{coordinator: coordinator} do
      {_workshop, [{_intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()

      assert {:ok, _} = pay(token)
      assert {:error, :payment_in_progress} = pay(token, @hold_ends)
    end

    test "a session Stripe refuses to create frees the hold at once", %{coordinator: coordinator} do
      {workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.fail_create(400)

      assert {:error, :payment_unavailable} = pay(token)

      assert [%IntakePayment{status: "released", stripe_checkout_session_id: nil}] =
               payments(intake)

      assert %{holds: 0} = seats(workshop)
    end

    test "when Stripe is unreachable the hold stays and the next press replays the create",
         %{coordinator: coordinator} do
      {workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.fail_create(500)

      assert {:error, :payment_unavailable} = pay(token)

      assert [%IntakePayment{status: "open", stripe_checkout_session_id: nil} = row] =
               payments(intake)

      assert %{holds: 1} = seats(workshop)

      Stripe.stub_create()
      assert {:ok, %{checkout_url: _}} = pay(token, DateTime.add(@now, 60))
      assert_received {:checkout_created, _form, "beginners-intake-payment:" <> id}
      assert id == row.id
      assert [%IntakePayment{status: "open"}] = payments(intake)
    end
  end

  describe "complete_payment" do
    test "pays the Intake through Stripe, queues Place confirmed – paid once, and is idempotent",
         %{coordinator: coordinator} do
      {workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(token)
      row = payment!(intake)
      session = Stripe.session(row)

      assert {:ok, %{outcome: :paid}} = complete(session)
      assert {:ok, %{outcome: :already_recorded}} = complete(session)

      assert %IntakePayment{status: "paid", paid_at: @now, stripe_payment_intent_id: "pi_" <> _} =
               Repo.reload!(row)

      assert %Intake{state: "paid", paid_via: "stripe", paid_at: @now} = Repo.reload!(intake)
      assert %{paid: 1, holds: 0} = seats(workshop)

      assert [%{args: %{"transactional_id" => "beginnersWorkshopAction"}}] = confirmed_jobs()

      assert [%IntakeEmailLog{email_type: "place_confirmed_paid", occasion: "place_confirmed"}] =
               Repo.all(
                 from(l in IntakeEmailLog,
                   where: l.intake_id == ^intake.id and l.occasion == "place_confirmed"
                 )
               )
    end

    test "the success return retrieves the session server-side", %{coordinator: coordinator} do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(token)
      row = payment!(intake)
      Stripe.stub_retrieve(Stripe.session(row))

      assert {:ok, %{outcome: :paid}} = complete(Stripe.session_id(row))
      assert %Intake{state: "paid"} = Repo.reload!(intake)
    end

    test "an open session is not a payment", %{coordinator: coordinator} do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(token)
      row = payment!(intake)

      assert {:ok, %{outcome: :not_paid}} =
               complete(Stripe.session(row, %{"status" => "open", "payment_status" => "unpaid"}))

      assert %IntakePayment{status: "open"} = Repo.reload!(row)
    end

    test "an amount or currency mismatch fails the policy and leaves the Intake contacted",
         %{coordinator: coordinator} do
      {_workshop, [{first, first_token}, {second, second_token}]} =
        contacted_fixture(coordinator, 2)

      Stripe.stub_create()
      assert {:ok, _} = pay(first_token)
      assert {:ok, _} = pay(second_token)

      assert {:ok, %{outcome: :policy_failed}} =
               complete(Stripe.session(payment!(first), %{"amount_total" => 100}))

      assert {:ok, %{outcome: :policy_failed}} =
               complete(Stripe.session(payment!(second), %{"currency" => "gbp"}))

      assert %IntakePayment{status: "policy_failed", amount_received_cents: 100} = payment!(first)
      assert %IntakePayment{status: "policy_failed", currency_received: "gbp"} = payment!(second)

      for intake <- [first, second],
          do: assert(%Intake{state: "contacted"} = Repo.reload!(intake))

      assert confirmed_jobs() == []
    end

    test "a session that is not an Intake payment is ignored; one not recorded yet retries",
         %{coordinator: coordinator} do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)

      assert {:ok, %{outcome: :not_ours}} =
               complete(%{"id" => "cs_workshop_guest", "status" => "complete", "metadata" => %{}})

      Stripe.fail_create(500)
      assert {:error, :payment_unavailable} = pay(token)
      row = payment!(intake)
      assert {:error, :session_not_recorded} = complete(Stripe.session(row))
    end

    test "only Stripe may complete or release a payment", %{coordinator: coordinator} do
      assert {:error, :forbidden} =
               BeginnersWorkshops.execute({:staff, coordinator}, {:complete_payment, "cs_1"})

      assert {:error, :forbidden} =
               BeginnersWorkshops.execute(:system, {:release_payment, "cs_1"})
    end
  end

  describe "release_payment" do
    test "an expired session releases its hold once; a session still open releases nothing",
         %{coordinator: coordinator} do
      {workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(token)
      row = payment!(intake)

      assert {:ok, %{outcome: :not_expired}} = release(Stripe.session(row, %{"status" => "open"}))
      assert %{holds: 1} = seats(workshop)

      expired = Stripe.session(row, %{"status" => "expired", "payment_status" => "unpaid"})
      assert {:ok, %{outcome: :released}} = release(expired)
      assert {:ok, %{outcome: :already_recorded}} = release(expired)

      assert %IntakePayment{status: "released", released_at: @now} = Repo.reload!(row)
      assert %Intake{state: "contacted"} = Repo.reload!(intake)
      assert %{holds: 0} = seats(workshop)
    end
  end

  describe "reap_holds" do
    test "asks Stripe to expire sessions whose hold ran out and releases them only then",
         %{coordinator: coordinator} do
      {workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(token)
      row = payment!(intake)

      # Not run out yet: Stripe is not asked.
      assert {:ok, %{released: 0, completed: 0, waiting: 0}} = reap(DateTime.add(@hold_ends, -1))

      # Stripe cannot be reached: the seat stays taken.
      Dhc.StripeHTTPStub.stub(
        "POST",
        "/v1/checkout/sessions/#{Stripe.session_id(row)}/expire",
        fn conn ->
          Dhc.StripeHTTPStub.stripe_error(conn, 503)
        end
      )

      Dhc.StripeHTTPStub.stub("GET", "/v1/checkout/sessions/#{Stripe.session_id(row)}", fn conn ->
        Dhc.StripeHTTPStub.stripe_error(conn, 503)
      end)

      assert {:ok, %{waiting: 1}} = reap(@hold_ends)
      assert %{holds: 1} = seats(workshop)

      Stripe.stub_expire(Stripe.session(row, %{"status" => "open", "payment_status" => "unpaid"}))
      assert {:ok, %{released: 1}} = reap(@hold_ends)
      assert %IntakePayment{status: "released"} = Repo.reload!(row)
      assert %{holds: 0} = seats(workshop)
    end

    test "a session that completed before it could be expired is paid", %{
      coordinator: coordinator
    } do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(token)
      row = payment!(intake)
      Stripe.refuse_expire(Stripe.session_id(row))
      Stripe.stub_retrieve(Stripe.session(row))

      assert {:ok, %{completed: 1}} = reap(@hold_ends)
      assert %Intake{state: "paid"} = Repo.reload!(intake)
    end

    test "a hold whose session was never recorded replays the create, or is freed when Stripe has none",
         %{coordinator: coordinator} do
      {_workshop, [{first, first_token}, {second, second_token}]} =
        contacted_fixture(coordinator, 2)

      Stripe.fail_create(500)
      assert {:error, :payment_unavailable} = pay(first_token)
      assert {:error, :payment_unavailable} = pay(second_token)
      first_row = payment!(first)
      second_row = payment!(second)

      # The replay of the first row's create returns the session Stripe made.
      Dhc.StripeHTTPStub.stub("POST", "/v1/checkout/sessions", fn conn ->
        case Dhc.StripeHTTPStub.header(conn, "idempotency-key") do
          "beginners-intake-payment:" <> id when id == first_row.id ->
            Dhc.StripeHTTPStub.json(conn, %{
              "id" => Stripe.session_id(first_row),
              "url" => Stripe.checkout_url(Stripe.session_id(first_row))
            })

          _second ->
            Dhc.StripeHTTPStub.stripe_error(conn, 400, %{"message" => "expires_at too soon"})
        end
      end)

      Stripe.stub_expire(Stripe.session(first_row, %{"status" => "open"}))

      assert {:ok, %{released: 2}} = reap(@hold_ends)
      assert %IntakePayment{status: "released"} = Repo.reload!(first_row)
      assert Repo.reload!(first_row).stripe_checkout_session_id == Stripe.session_id(first_row)

      assert %IntakePayment{status: "released", stripe_checkout_session_id: nil} =
               Repo.reload!(second_row)
    end

    test "the sweep runs the reaper", %{coordinator: coordinator} do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(token)
      Stripe.stub_expire(Stripe.session(payment!(intake), %{"status" => "open"}))

      assert %{holds_released: 1, failed: 0} =
               BeginnersWorkshops.run_due_passes(clock: at(@hold_ends))
    end
  end

  describe "update_workshop capacity" do
    test "cannot go below the seats taken (paid + live holds)", %{coordinator: coordinator} do
      {workshop, [{first, first_token}, {_second, second_token}, _third]} =
        contacted_fixture(coordinator, 3)

      paid_through_stripe(first_token, first)
      assert {:ok, _} = pay(second_token)

      update = fn capacity ->
        BeginnersWorkshops.execute(
          {:staff, coordinator},
          {:update_workshop, workshop.id, %{"capacity" => capacity}},
          clock: at()
        )
      end

      assert {:error, :capacity_below_taken} = update.(1)
      assert {:ok, %{capacity: 2}} = update.(2)
      assert {:ok, %{capacity: 5}} = update.(5)
    end
  end

  describe "the stage" do
    test "a workshop whose seats are all paid or held is full", %{coordinator: coordinator} do
      {workshop, [{_intake, token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(token)

      %{upcoming: rows} = BeginnersWorkshops.list_workshops(clock: at())
      assert Enum.find(rows, &(&1.id == workshop.id)).stage == :full
    end
  end

  describe "the transition table" do
    test "declares the Intake and payment-row moves" do
      transitions = Commands.transitions()

      assert transitions.intake == %{
               "contacted" => ~w(paid lapsed returned declined),
               "paid" => ~w(attended no_show cancelled_refunded withdrawn)
             }

      assert transitions.payment == %{
               "open" => ~w(paid releasing released policy_failed),
               "releasing" => ~w(released paid)
             }

      for from <- ~w(paid released policy_failed),
          to <- IntakePayment.statuses(),
          do: refute(Commands.transition_allowed?(:payment, from, to))

      refute Commands.transition_allowed?(:payment, "releasing", "open")
      refute Commands.transition_allowed?(:intake, "paid", "contacted")
    end
  end

  describe "Stripe webhooks" do
    test "checkout.session.completed completes and checkout.session.expired releases",
         %{coordinator: coordinator} do
      {_workshop, [{first, first_token}, {second, second_token}]} =
        contacted_fixture(coordinator, 2)

      Stripe.stub_create()
      assert {:ok, _} = pay(first_token)
      assert {:ok, _} = pay(second_token)

      assert :ok =
               StripeWebhooks.process_event(
                 Stripe.event("checkout.session.completed", Stripe.session(payment!(first)))
               )

      assert :ok =
               StripeWebhooks.process_event(
                 Stripe.event(
                   "checkout.session.expired",
                   Stripe.session(payment!(second), %{"status" => "expired"})
                 )
               )

      assert %Intake{state: "paid"} = Repo.reload!(first)
      assert %IntakePayment{status: "released"} = payment!(second)

      # A Workshop guest checkout is acknowledged without effect.
      assert :ok =
               StripeWebhooks.process_event(
                 Stripe.event("checkout.session.completed", %{
                   "id" => "cs_guest",
                   "metadata" => %{}
                 })
               )
    end
  end
end
