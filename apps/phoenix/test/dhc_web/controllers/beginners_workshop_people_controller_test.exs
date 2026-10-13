defmodule DhcWeb.BeginnersWorkshopPeopleControllerTest do
  @moduledoc """
  ALE-417 contract tests over HTTP: `GET /beginners-workshops/people` — each
  listed person's workshop credit, the person commands the Waitlist tab may
  offer and the refund-or-forfeit choice an offered Withdraw or Delete
  needs. The HTTP path runs on the wall clock, so workshops are dated
  relative to today.
  """
  use DhcWeb.ConnCase, async: false

  import Dhc.BeginnersWorkshopFixtures
  import Ecto.Query

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshops.{CarriedFee, IntakePayment}
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator coach)

  setup do
    role_subs =
      Map.new(@roles, fn role ->
        member = Dhc.MemberFixtures.member_fixture(%{first_name: String.capitalize(role)})
        Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})
        {role, member.principal_id}
      end)

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    date = Date.add(ClubCalendar.today(), 40)

    workshop =
      scheduled_fixture(role_subs["beginners_coordinator"], %{"date" => Date.to_iso8601(date)},
        clock: clock(DateTime.utc_now())
      )

    %{workshop: workshop}
  end

  defp as_coordinator(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer beginners_coordinator-token")

  defp people_path(ids), do: "/api/beginners-workshops/people?waitlistIds=#{Enum.join(ids, ",")}"

  defp people(conn, ids),
    do: conn |> as_coordinator() |> get(people_path(ids)) |> json_response(200) |> Map.get("data")

  defp person!(opts \\ []), do: waiting_person_fixture(~U[2025-01-01 12:00:00Z], opts)

  defp held_fee!(person) do
    Repo.insert!(%CarriedFee{
      waitlist_id: person.id,
      status: "held",
      origin: "import",
      imported_paid_text: "Paid",
      stripe_payment_intent_id: "pi_#{System.unique_integer([:positive])}",
      amount_cents: 3500,
      status_changed_at: DateTime.utc_now()
    })
  end

  defp stripe_paid!(workshop, person) do
    {intake, _token} = intake_fixture!(workshop.id, person, DateTime.utc_now())
    intake = force_intake_state!(intake.id, "paid")

    Repo.insert!(%IntakePayment{
      workshop_id: workshop.id,
      intake_id: intake.id,
      status: "paid",
      amount_cents: 4000,
      expires_at: DateTime.utc_now(),
      stripe_checkout_session_id: "cs_#{intake.id}",
      stripe_payment_intent_id: "pi_#{intake.id}",
      amount_received_cents: 4000,
      currency_received: "eur",
      paid_at: DateTime.utc_now()
    })
  end

  test "needs beginners.waitlist.manage and at most 100 Waitlist ids", %{conn: conn} do
    path = people_path([Ecto.UUID.generate()])

    assert conn |> get(path) |> json_response(401)

    assert conn
           |> Plug.Conn.put_req_header("authorization", "Bearer coach-token")
           |> get(path)
           |> json_response(403)

    for query <- ["nope", Enum.map_join(1..101, ",", fn _ -> Ecto.UUID.generate() end)] do
      assert conn
             |> as_coordinator()
             |> get("/api/beginners-workshops/people?waitlistIds=#{query}")
             |> json_response(422)
    end

    assert conn
           |> as_coordinator()
           |> get("/api/beginners-workshops/people")
           |> json_response(422)
  end

  test "every Waitlist id is present with its credit, commands and refund choice; unknown ids are absent",
       %{conn: conn, workshop: workshop} do
    plain = person!()
    holder = person!()
    held_fee!(holder)
    payer = person!()
    stripe_paid!(workshop, payer)
    removed = person!(status: "removed")
    unknown = Ecto.UUID.generate()

    data = people(conn, [plain.id, holder.id, payer.id, removed.id, unknown])

    assert Map.keys(data) |> Enum.sort() == Enum.sort([plain.id, holder.id, payer.id, removed.id])

    assert data[plain.id] == %{
             "carriedFee" => nil,
             "availableCommands" => ["withdraw", "delete_person"],
             "refundChoice" => nil
           }

    # A held credit: refunded or forfeited by Withdraw or Delete.
    assert data[holder.id] == %{
             "carriedFee" => "held",
             "availableCommands" => ["withdraw", "delete_person", "refund_carried_fee"],
             "refundChoice" => %{
               "source" => "carried_fee",
               "amountCents" => 3500,
               "currency" => "eur"
             }
           }

    # A paid Intake: only Withdraw, settling the payment that paid it.
    assert data[payer.id] == %{
             "carriedFee" => nil,
             "availableCommands" => ["withdraw"],
             "refundChoice" => %{
               "source" => "payment",
               "amountCents" => 4000,
               "currency" => "eur"
             }
           }

    # Already withdrawn, with nothing to settle.
    assert data[removed.id] == %{
             "carriedFee" => nil,
             "availableCommands" => ["delete_person"],
             "refundChoice" => nil
           }
  end

  test "Delete is not offered for a person whose profile a Member claimed", %{conn: conn} do
    person = person!()
    principal = Dhc.AuthFixtures.principal_fixture()

    Repo.update_all(
      from(p in Dhc.UserProfiles.UserProfile, where: p.waitlist_id == ^person.id),
      set: [principal_id: principal.id]
    )

    assert %{"availableCommands" => ["withdraw"]} = people(conn, [person.id])[person.id]
  end
end
