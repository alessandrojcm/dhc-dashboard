defmodule DhcWeb.BeginnersWorkshopIntakeControllerTest do
  @moduledoc """
  ALE-381 contract test for the public `beginnersWorkshopIntake` slice: the
  Intake page view, `startPayment` (Checkout URL, `full`), the success
  return, `Referrer-Policy: no-referrer` on every response, and the token
  kept out of the request log and Sentry. The HTTP path runs on the wall
  clock, so the workshop is dated relative to today.
  """
  use DhcWeb.ConnCase, async: false

  import Dhc.BeginnersWorkshopFixtures
  import Ecto.Query

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops.IntakePayment
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias DhcWeb.IntakeLinkPrivacy

  setup do
    coordinator = staff_fixture("beginners_coordinator")
    date = Date.add(ClubCalendar.today(), 40)

    workshop =
      scheduled_fixture(
        coordinator,
        %{"date" => Date.to_iso8601(date), "capacity" => 1},
        clock: clock(DateTime.utc_now())
      )

    [first, second] = waiting_people_fixture(2)
    {intake, token} = intake_fixture!(workshop.id, first, DateTime.utc_now())
    {_other, other_token} = intake_fixture!(workshop.id, second, DateTime.utc_now())

    Stripe.stub_create()

    %{workshop: workshop, intake: intake, token: token, other_token: other_token, date: date}
  end

  defp no_referrer?(conn), do: get_resp_header(conn, "referrer-policy") == ["no-referrer"]

  test "GET answers the closed safe view with no-referrer and no ids", %{
    conn: conn,
    token: token,
    date: date
  } do
    conn = get(conn, "/api/beginners/intake/#{token}")

    assert no_referrer?(conn)
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert %{
             "data" =>
               %{
                 "state" => "pay",
                 "action" => "pay",
                 "closedReason" => nil,
                 "firstName" => "Person" <> _,
                 "workshop" => %{
                   "date" => iso_date,
                   "startTime" => "18:30",
                   "venue" => "St. Andrew's Hall"
                 },
                 "feeCents" => 4000
               } = data
           } = json_response(conn, 200)

    assert iso_date == Date.to_iso8601(date)

    assert Map.keys(data) |> Enum.sort() ==
             ~w(action closedReason feeCents firstName state workshop)
  end

  test "an unknown link is 404, still without a referrer", %{conn: conn} do
    conn = get(conn, "/api/beginners/intake/not-a-link")
    assert no_referrer?(conn)

    assert %{"errors" => %{"detail" => "This link is no longer active"}} =
             json_response(conn, 404)

    conn = post(build_conn(), "/api/beginners/intake/#{String.duplicate("x", 200)}/payment")
    assert json_response(conn, 404)
  end

  test "startPayment answers the Checkout URL; the next person for the last seat sees full",
       %{conn: conn, intake: intake, token: token, other_token: other_token} do
    conn = post(conn, "/api/beginners/intake/#{token}/payment")
    assert no_referrer?(conn)
    assert %{"data" => %{"checkoutUrl" => url}} = json_response(conn, 200)

    row = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))
    assert url == Stripe.checkout_url(Stripe.session_id(row))

    conn = post(build_conn(), "/api/beginners/intake/#{other_token}/payment")
    assert no_referrer?(conn)
    assert %{"errors" => %{"code" => "full"}} = json_response(conn, 409)

    assert %{"data" => %{"state" => "full", "action" => "check_again"}} =
             build_conn() |> get("/api/beginners/intake/#{other_token}") |> json_response(200)
  end

  test "the success return completes the payment from the retrieved session, then shows paid",
       %{conn: conn, intake: intake, token: token} do
    post(conn, "/api/beginners/intake/#{token}/payment")
    row = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))

    # Stripe has not finished: the page waits.
    Stripe.stub_retrieve(Stripe.session(row, %{"status" => "open", "payment_status" => "unpaid"}))

    conn =
      post(build_conn(), "/api/beginners/intake/#{token}/return", %{
        "sessionId" => Stripe.session_id(row)
      })

    assert no_referrer?(conn)
    assert %{"data" => %{"state" => "payment_in_progress"}} = json_response(conn, 200)

    Stripe.stub_retrieve(Stripe.session(row))

    assert %{"data" => %{"state" => "paid", "action" => "none"}} =
             build_conn()
             |> post("/api/beginners/intake/#{token}/return", %{
               "sessionId" => Stripe.session_id(row)
             })
             |> json_response(200)
  end

  test "the request log carries the redacted path, never the token", %{token: token} do
    conn = Plug.Test.conn(:get, "/api/beginners/intake/#{token}/payment")

    # Phoenix's own request line is off for Intake link paths; the plug logs
    # this one instead.
    assert IntakeLinkPrivacy.log_level(conn) == false
    assert IntakeLinkPrivacy.log_level(Plug.Test.conn(:get, "/api/health")) == :info

    line = DhcWeb.Plugs.IntakeLinkPage.request_line(conn)
    assert line =~ "GET /api/beginners/intake/[REDACTED]/payment from "
    refute line =~ token
  end

  test "Sentry's request URL, events and transactions redact the token", %{token: token} do
    conn = Plug.Test.conn(:get, "/api/beginners/intake/#{token}?session_id=cs_1")
    refute IntakeLinkPrivacy.scrub_url(conn) =~ token
    assert IntakeLinkPrivacy.scrub_url(conn) =~ "/beginners/intake/[REDACTED]"

    event = %Sentry.Event{
      event_id: "abc",
      timestamp: "2026-10-09T12:00:00",
      message: %Sentry.Interfaces.Message{formatted: "failed GET /api/beginners/intake/#{token}"},
      request: %Sentry.Interfaces.Request{
        url: "https://api.example.com/api/beginners/intake/#{token}"
      },
      breadcrumbs: [%{message: "navigated to /beginners/intake/#{token}/"}]
    }

    refute inspect(IntakeLinkPrivacy.before_send(event)) =~ token

    transaction = %Sentry.Transaction{
      event_id: "def",
      span_id: "root",
      start_timestamp: "2026-10-09T12:00:00",
      timestamp: "2026-10-09T12:00:01",
      transaction: "GET /api/beginners/intake/:token",
      spans: [
        %Sentry.Interfaces.Span{
          trace_id: "t",
          span_id: "s",
          start_timestamp: "2026-10-09T12:00:00",
          timestamp: "2026-10-09T12:00:01",
          op: "http.server",
          description: "GET /api/beginners/intake/#{token}",
          data: %{"url.path" => "/api/beginners/intake/#{token}"}
        }
      ]
    }

    redacted = IntakeLinkPrivacy.before_send(transaction)
    refute inspect(redacted) =~ token

    assert %Sentry.Transaction{spans: [%Sentry.Interfaces.Span{description: description}]} =
             redacted

    assert description == "GET /api/beginners/intake/[REDACTED]"
  end
end
