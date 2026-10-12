defmodule DhcWeb.BeginnersWorkshopCarriedFeesControllerTest do
  @moduledoc """
  ALE-388 contract tests over HTTP: the console's Defer and Confirm Intake
  commands, the person's `POST /beginners/intake/{token}/confirm` with the
  `confirm` safe-view state, `startPayment`'s `confirm_instead`, the
  console's Carried Fee fields, and the Waitlist view's
  `GET /beginners-workshops/carried-fees`. The HTTP path runs on the wall
  clock, so workshops are dated relative to today.
  """
  use DhcWeb.ConnCase, async: false

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{CarriedFee, Intake}
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

    [holder, payer] = waiting_people_fixture(2)

    {:ok, %{outcome: :created}} =
      BeginnersWorkshops.execute(:system, {:import_carried_fee, holder.id, "Yes"})

    {holder_intake, holder_token} = intake_fixture!(workshop.id, holder, DateTime.utc_now())
    {payer_intake, payer_token} = intake_fixture!(workshop.id, payer, DateTime.utc_now())

    %{
      workshop: workshop,
      holder: holder,
      payer: payer,
      holder_intake: holder_intake,
      holder_token: holder_token,
      payer_intake: payer_intake,
      payer_token: payer_token
    }
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp intake_path(workshop, intake_id, action),
    do: "/api/beginners-workshops/#{workshop.id}/intakes/#{intake_id}/#{action}"

  test "the person's page offers confirm, and confirming answers the paid page", %{
    conn: conn,
    holder: holder,
    holder_token: token
  } do
    assert %{"data" => %{"state" => "confirm", "action" => "confirm", "feeCents" => nil}} =
             conn |> get("/api/beginners/intake/#{token}") |> json_response(200)

    conn = post(build_conn(), "/api/beginners/intake/#{token}/confirm")
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert %{"data" => %{"state" => "paid", "action" => "none"}} = json_response(conn, 200)

    assert %CarriedFee{status: "applied"} = Repo.get_by!(CarriedFee, waitlist_id: holder.id)

    # Pressing again answers the same page.
    assert %{"data" => %{"state" => "paid"}} =
             build_conn() |> post("/api/beginners/intake/#{token}/confirm") |> json_response(200)
  end

  test "a holder can't pay, a payer can't confirm, and an unknown link is 404", %{
    holder_token: holder_token,
    payer_token: payer_token
  } do
    assert %{"errors" => %{"code" => "confirm_instead"}} =
             build_conn()
             |> post("/api/beginners/intake/#{holder_token}/payment")
             |> json_response(409)

    assert %{"errors" => %{"code" => "no_carried_fee"}} =
             build_conn()
             |> post("/api/beginners/intake/#{payer_token}/confirm")
             |> json_response(409)

    assert build_conn() |> post("/api/beginners/intake/not-a-link/confirm") |> json_response(404)
  end

  test "staff confirm and defer; the console carries the Carried Fee", %{
    conn: conn,
    workshop: w,
    holder: holder,
    holder_intake: holder_intake,
    payer_intake: payer_intake
  } do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => console} =
             coordinator
             |> get("/api/beginners-workshops/#{w.id}/console")
             |> json_response(200)

    assert [%{"id" => unconfirmed}] = console["unconfirmedCarriedFees"]
    assert unconfirmed == holder_intake.id
    assert console["fastTrackHoldersOnly"] == false

    asked = Map.new(console["roster"]["asked"], &{&1["id"], &1})
    assert asked[holder_intake.id]["carriedFee"] == "held"
    assert "confirm" in asked[holder_intake.id]["availableCommands"]
    assert asked[payer_intake.id]["carriedFee"] == nil

    assert %{"errors" => %{"code" => "no_carried_fee"}} =
             coordinator
             |> post(intake_path(w, payer_intake.id, "confirm"), %{})
             |> json_response(409)

    assert %{"data" => %{"state" => "paid", "outcome" => "done"}} =
             coordinator
             |> post(intake_path(w, holder_intake.id, "confirm"), %{"note" => "Replied by email"})
             |> json_response(200)

    assert %{"errors" => %{"code" => "intake_not_paid"}} =
             coordinator
             |> post(intake_path(w, payer_intake.id, "defer"), %{})
             |> json_response(409)

    assert %{"data" => %{"state" => "deferred", "outcome" => "done"}} =
             coordinator
             |> post(intake_path(w, holder_intake.id, "defer"), %{})
             |> json_response(200)

    assert %Intake{state: "deferred"} = Repo.reload!(holder_intake)
    assert %CarriedFee{status: "held"} = Repo.get_by!(CarriedFee, waitlist_id: holder.id)

    for role <- ~w(coach member),
        do:
          assert(
            conn
            |> as_role(role)
            |> post(intake_path(w, payer_intake.id, "confirm"), %{})
            |> json_response(403)
          )
  end

  test "the Waitlist view reads Carried Fee statuses by entry id", %{
    conn: conn,
    holder: holder,
    payer: payer
  } do
    path = "/api/beginners-workshops/carried-fees?waitlistIds=#{holder.id},#{payer.id}"

    assert conn |> get(path) |> json_response(401)
    assert conn |> as_role("coach") |> get(path) |> json_response(403)

    holder_id = holder.id

    assert %{"data" => %{^holder_id => "held"} = data} =
             conn |> as_role("beginners_coordinator") |> get(path) |> json_response(200)

    assert map_size(data) == 1

    assert conn
           |> as_role("beginners_coordinator")
           |> get("/api/beginners-workshops/carried-fees?waitlistIds=nope")
           |> json_response(422)
  end

  test "startPayment still works for a payer", %{payer_token: token} do
    Stripe.stub_create()

    assert %{"data" => %{"checkoutUrl" => _}} =
             build_conn() |> post("/api/beginners/intake/#{token}/payment") |> json_response(200)
  end
end
