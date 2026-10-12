defmodule DhcWeb.BeginnersWorkshopRefundsControllerTest do
  @moduledoc """
  ALE-382 contract test for the `beginnersWorkshopRefunds` slice: the
  capability gate, Retry and Record manual refund on a failed refund, each
  refusal's status and code, and the console's refund status and
  `failedRefunds`.
  """
  use DhcWeb.ConnCase, async: false

  import Ecto.Query

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, IntakePayment, IntakeRefund}
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator coach member)
  @now ~U[2026-10-22 12:00:00.000000Z]

  setup do
    role_subs =
      Map.new(@roles, fn role ->
        member = Dhc.MemberFixtures.member_fixture()

        if role != "member",
          do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

        {role, member.principal_id}
      end)

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    {workshop, [{intake, token}]} =
      BeginnersWorkshopFixtures.contacted_fixture(role_subs["beginners_coordinator"], 1)

    clock = [clock: Clock.fixed(@now)]
    Stripe.stub_create()
    {:ok, _} = BeginnersWorkshops.execute({:intake_link, token}, :start_payment, clock)
    payment = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))

    {:ok, %{outcome: :policy_failed}} =
      BeginnersWorkshops.execute(
        :stripe,
        {:complete_payment, Stripe.session(payment, %{"amount_total" => 3500})},
        clock
      )

    refund = Repo.one!(from(r in IntakeRefund, where: r.payment_id == ^payment.id))
    Stripe.fail_refund_create(400)
    {:ok, %{outcome: :failed}} = BeginnersWorkshops.execute(:system, {:submit_refund, refund.id})

    %{workshop: workshop, intake: intake, refund: refund}
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp refund_path(workshop, refund_id, action),
    do: "/api/beginners-workshops/#{workshop.id}/refunds/#{refund_id}/#{action}"

  test "only managers follow up a failed refund", %{conn: conn, workshop: w, refund: r} do
    assert conn |> post(refund_path(w, r.id, "retry")) |> json_response(401)

    for role <- ~w(coach member) do
      assert conn |> as_role(role) |> post(refund_path(w, r.id, "retry")) |> json_response(403)

      assert conn
             |> as_role(role)
             |> post(refund_path(w, r.id, "manual"), %{})
             |> json_response(403)
    end
  end

  test "the console shows the failed refund under Needs attention, and Retry creates a new one",
       %{conn: conn, workshop: w, intake: intake, refund: r} do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => %{"failedRefunds" => [failed], "roster" => %{"asked" => [row]}}} =
             coordinator
             |> get("/api/beginners-workshops/#{w.id}/console")
             |> json_response(200)

    assert %{"id" => failed_id, "intakeId" => intake_id, "amountCents" => 3500} = failed
    assert failed_id == r.id
    assert intake_id == intake.id

    assert row["refund"] == %{
             "status" => "failed",
             "method" => "stripe",
             "automatic" => true,
             "amountCents" => 3500,
             "currency" => "eur"
           }

    assert %{
             "data" => %{
               "status" => "pending",
               "method" => "stripe",
               "followsRefundId" => follows
             }
           } =
             coordinator |> post(refund_path(w, r.id, "retry")) |> json_response(201)

    assert follows == r.id

    assert %{"data" => %{"failedRefunds" => []}} =
             coordinator
             |> get("/api/beginners-workshops/#{w.id}/console")
             |> json_response(200)

    assert %{"errors" => %{"code" => "refund_followed_up"}} =
             coordinator |> post(refund_path(w, r.id, "retry")) |> json_response(409)
  end

  test "Record manual refund records a completed manual refund",
       %{conn: conn, workshop: w, refund: r} do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => %{"status" => "completed", "method" => "manual", "id" => manual_id}} =
             coordinator
             |> post(refund_path(w, r.id, "manual"), %{"note" => "Paid back by bank transfer"})
             |> json_response(201)

    assert %{"errors" => %{"code" => "refund_not_failed"}} =
             coordinator |> post(refund_path(w, manual_id, "retry")) |> json_response(409)

    assert coordinator
           |> post(refund_path(w, Ecto.UUID.generate(), "manual"), %{})
           |> json_response(404)
  end
end
