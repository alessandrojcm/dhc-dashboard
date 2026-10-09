defmodule DhcWeb.BeginnersWorkshopCarriedFeeRefundsControllerTest do
  @moduledoc """
  ALE-389 contract tests over HTTP: the console's Refund Carried Fee Intake
  command and Needs attention's Forfeit, and the Waitlist tab's Carried Fee
  routes — the fee's view, Refund Carried Fee, Link Stripe payment and the
  failed refund's Retry, Record manual refund and Forfeit — with their
  refusals and capability gates. Stripe is stubbed at the HTTP seam; the
  HTTP path runs on the wall clock, so workshops are dated relative to today.
  """
  use DhcWeb.ConnCase, async: false

  import Dhc.BeginnersWorkshopFixtures
  import Ecto.Query

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{CarriedFee, IntakeRefund}
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator coach member)

  setup do
    role_subs =
      Map.new(@roles, fn role ->
        member = Dhc.MemberFixtures.member_fixture(%{first_name: String.capitalize(role)})

        if role != "member",
          do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

        {role, member.principal_id}
      end)

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    coordinator = role_subs["beginners_coordinator"]
    date = Date.add(ClubCalendar.today(), 40)

    workshop =
      scheduled_fixture(coordinator, %{"date" => Date.to_iso8601(date), "capacity" => 2},
        clock: clock(DateTime.utc_now())
      )

    [holder] = waiting_people_fixture(1)

    {:ok, %{outcome: :created}} =
      BeginnersWorkshops.execute(:system, {:import_carried_fee, holder.id, "Yes"})

    {holder_intake, _token} = intake_fixture!(workshop.id, holder, DateTime.utc_now())

    %{workshop: workshop, holder: holder, holder_intake: holder_intake}
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp person_path(holder, action \\ ""),
    do: "/api/beginners-workshops/people/#{holder.id}/carried-fee#{action}"

  defp link!(conn, holder, payment_intent_id \\ "pi_imported") do
    Stripe.stub_payment_intent(payment_intent_id, %{"amount_received" => 3500})

    conn
    |> as_role("beginners_coordinator")
    |> post(person_path(holder, "/link-payment"), %{"paymentIntentId" => payment_intent_id})
    |> json_response(200)
  end

  defp failed_refund!(holder) do
    [refund] =
      Repo.all(
        from(r in IntakeRefund,
          join: f in CarriedFee,
          on: f.id == r.carried_fee_id,
          where: f.waitlist_id == ^holder.id
        )
      )

    Stripe.fail_refund_create(400)
    {:ok, %{outcome: :failed}} = BeginnersWorkshops.execute(:system, {:submit_refund, refund.id})
    refund
  end

  test "the Waitlist tab links an imported fee, refunds it and follows up its failed refund",
       %{conn: conn, holder: holder} do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => %{"linked" => false, "availableCommands" => ["link_payment"]}} =
             coordinator |> get(person_path(holder)) |> json_response(200)

    assert %{"errors" => %{"code" => "payment_not_linked"}} =
             coordinator |> post(person_path(holder, "/refund"), %{}) |> json_response(409)

    assert %{"errors" => %{"code" => "invalid_payment_reference", "fields" => fields}} =
             coordinator
             |> post(person_path(holder, "/link-payment"), %{"paymentIntentId" => "ch_1"})
             |> json_response(422)

    assert Map.has_key?(fields, "paymentIntentId")

    Stripe.fail_payment_intent("pi_missing", 404)

    assert %{"errors" => %{"code" => "stripe_payment_not_found"}} =
             coordinator
             |> post(person_path(holder, "/link-payment"), %{"paymentIntentId" => "pi_missing"})
             |> json_response(409)

    assert %{"data" => %{"amountCents" => 3500, "outcome" => "done"}} = link!(conn, holder)

    assert %{"data" => %{"carriedFee" => %{"status" => "refunded"}, "outcome" => "done"}} =
             coordinator
             |> post(person_path(holder, "/refund"), %{"note" => "Asked by email"})
             |> json_response(200)

    refund = failed_refund!(holder)

    assert %{
             "data" => %{
               "status" => "held",
               "failedRefund" => %{"id" => id},
               "availableCommands" => ["retry", "manual", "forfeit"]
             }
           } = coordinator |> get(person_path(holder)) |> json_response(200)

    assert id == refund.id

    assert %{"data" => %{"status" => "forfeited", "refundId" => ^id}} =
             coordinator
             |> post(person_path(holder, "/refunds/#{id}/forfeit"), %{})
             |> json_response(200)

    assert %{"errors" => %{"code" => "carried_fee_not_held"}} =
             coordinator
             |> post(person_path(holder, "/refunds/#{id}/retry"), %{})
             |> json_response(409)
  end

  test "a failed Carried Fee refund is retried or recorded as manual from the Waitlist tab",
       %{conn: conn, holder: holder} do
    coordinator = as_role(conn, "beginners_coordinator")
    link!(conn, holder)
    coordinator |> post(person_path(holder, "/refund"), %{}) |> json_response(200)
    refund = failed_refund!(holder)

    assert %{"data" => %{"status" => "completed", "method" => "manual"}} =
             coordinator
             |> post(person_path(holder, "/refunds/#{refund.id}/manual"), %{"note" => "Cash"})
             |> json_response(201)

    assert %{"errors" => %{"code" => "refund_followed_up"}} =
             coordinator
             |> post(person_path(holder, "/refunds/#{refund.id}/retry"), %{})
             |> json_response(409)
  end

  test "the console refunds a contacted holder's fee and forfeits it after a failed refund",
       %{conn: conn, workshop: w, holder: holder, holder_intake: intake} do
    coordinator = as_role(conn, "beginners_coordinator")
    link!(conn, holder)

    assert %{"data" => console} =
             coordinator |> get("/api/beginners-workshops/#{w.id}/console") |> json_response(200)

    [row] = console["roster"]["asked"]
    assert "refund_carried_fee" in row["availableCommands"]

    assert %{"data" => %{"state" => "contacted", "outcome" => "done"}} =
             coordinator
             |> post(
               "/api/beginners-workshops/#{w.id}/intakes/#{intake.id}/refund-carried-fee",
               %{}
             )
             |> json_response(200)

    refund = failed_refund!(holder)

    assert %{"data" => %{"failedRefunds" => [%{"id" => id, "carriedFee" => true}]}} =
             coordinator |> get("/api/beginners-workshops/#{w.id}/console") |> json_response(200)

    assert id == refund.id

    assert %{"data" => %{"status" => "forfeited"}} =
             coordinator
             |> post("/api/beginners-workshops/#{w.id}/refunds/#{id}/forfeit", %{})
             |> json_response(200)

    assert %CarriedFee{status: "forfeited"} = Repo.get_by!(CarriedFee, waitlist_id: holder.id)
  end

  test "every Carried Fee route needs beginners.workshops.manage", %{
    conn: conn,
    workshop: w,
    holder: holder,
    holder_intake: intake
  } do
    refund_id = Ecto.UUID.generate()

    for role <- ~w(coach member) do
      member = as_role(conn, role)
      assert member |> get(person_path(holder)) |> json_response(403)
      assert member |> post(person_path(holder, "/refund"), %{}) |> json_response(403)

      assert member
             |> post(person_path(holder, "/link-payment"), %{"paymentIntentId" => "pi_1"})
             |> json_response(403)

      for action <- ~w(retry manual forfeit),
          do:
            assert(
              member
              |> post(person_path(holder, "/refunds/#{refund_id}/#{action}"), %{})
              |> json_response(403)
            )

      assert member
             |> post("/api/beginners-workshops/#{w.id}/refunds/#{refund_id}/forfeit", %{})
             |> json_response(403)

      assert member
             |> post(
               "/api/beginners-workshops/#{w.id}/intakes/#{intake.id}/refund-carried-fee",
               %{}
             )
             |> json_response(403)
    end

    assert conn |> get(person_path(holder)) |> json_response(401)

    nobody = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

    assert conn
           |> as_role("beginners_coordinator")
           |> get(person_path(nobody))
           |> json_response(404)
  end
end
