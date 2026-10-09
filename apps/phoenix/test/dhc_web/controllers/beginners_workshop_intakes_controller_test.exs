defmodule DhcWeb.BeginnersWorkshopIntakesControllerTest do
  @moduledoc """
  ALE-386 contract test for the `beginnersWorkshopIntakes` slice: the
  capability gate, Decline / Resend link / Rotate link with a note, each
  refusal's status and code, and the console Intake's new fields (medical
  flag, link generation, email log, history, `availableCommands`) and the
  `unpaidAfterWindow` Needs attention list. Responses are checked against
  the OpenAPI contract by `DhcWeb.OpenApiVerifier`.
  """
  use DhcWeb.ConnCase, async: false

  import Ecto.Query

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.BeginnersWorkshops.{Intake, IntakePayment, IntakeRefund}
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator coach member)

  setup do
    role_subs =
      Map.new(@roles, fn role ->
        member =
          Dhc.MemberFixtures.member_fixture(%{
            first_name: String.capitalize(role),
            last_name: "Staff"
          })

        if role != "member",
          do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

        {role, member.principal_id}
      end)

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    {workshop, [{contacted, _}, {paid, _}]} =
      BeginnersWorkshopFixtures.contacted_fixture(role_subs["beginners_coordinator"], 2)

    BeginnersWorkshopFixtures.force_intake_state!(paid.id, "paid")

    %{workshop: workshop, contacted: contacted, paid: paid}
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp intake_path(workshop, intake_id, action),
    do: "/api/beginners-workshops/#{workshop.id}/intakes/#{intake_id}/#{action}"

  defp console(conn, workshop),
    do: conn |> get("/api/beginners-workshops/#{workshop.id}/console") |> json_response(200)

  test "only managers run Intake commands", %{conn: conn, workshop: w, contacted: i} do
    for action <- ~w(decline resend-link rotate-link) do
      assert conn |> post(intake_path(w, i.id, action), %{}) |> json_response(401)

      for role <- ~w(coach member),
          do:
            assert(
              conn
              |> as_role(role)
              |> post(intake_path(w, i.id, action), %{})
              |> json_response(403)
            )
    end

    assert %Intake{state: "contacted", link_generation: 1} = Repo.reload!(i)
  end

  test "the console offers only the commands each Intake's state allows",
       %{conn: conn, workshop: w, contacted: contacted, paid: paid} do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => %{"roster" => %{"asked" => [asked], "seated" => [seated]}}} =
             console(coordinator, w)

    assert asked["id"] == contacted.id
    assert asked["availableCommands"] == ~w(decline withdraw resend_link rotate_link)
    assert asked["linkGeneration"] == 1
    assert asked["medical"] == false
    assert [%{"emailType" => "contact_pay", "scheduled" => false}] = asked["emailLog"]
    assert asked["history"] == []

    assert seated["id"] == paid.id

    assert seated["availableCommands"] ==
             ~w(defer cancel_with_refund withdraw resend_link rotate_link)

    assert [_contact, %{"emailType" => "pre_workshop", "scheduled" => true}] =
             seated["emailLog"]
  end

  test "Decline answers the declined Intake, then already_done; the history records the note",
       %{conn: conn, workshop: w, contacted: i} do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => %{"state" => "declined", "outcome" => "done", "linkGeneration" => 1}} =
             coordinator
             |> post(intake_path(w, i.id, "decline"), %{"note" => "Replied: next one"})
             |> json_response(200)

    assert %{"data" => %{"outcome" => "already_done"}} =
             coordinator |> post(intake_path(w, i.id, "decline"), %{}) |> json_response(200)

    assert %{"data" => %{"roster" => %{"out" => [out]}}} = console(coordinator, w)
    assert out["availableCommands"] == []

    assert [
             %{
               "command" => "decline",
               "actor" => "Beginners_coordinator Staff",
               "note" => "Replied: next one"
             }
           ] = out["history"]

    assert %{"errors" => %{"code" => "intake_closed"}} =
             coordinator |> post(intake_path(w, i.id, "resend-link"), %{}) |> json_response(409)
  end

  test "refusals carry their codes; an unknown Intake is 404",
       %{conn: conn, workshop: w, paid: paid} do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"errors" => %{"code" => "already_paid"}} =
             coordinator |> post(intake_path(w, paid.id, "decline"), %{}) |> json_response(409)

    assert %{"errors" => %{"code" => "invalid_note", "fields" => %{"note" => [_]}}} =
             coordinator
             |> post(intake_path(w, paid.id, "resend-link"), %{
               "note" => String.duplicate("x", 501)
             })
             |> json_response(422)

    assert coordinator
           |> post(intake_path(w, Ecto.UUID.generate(), "decline"), %{})
           |> json_response(404)
  end

  test "Resend link and Rotate link answer the Intake's link generation",
       %{conn: conn, workshop: w, paid: paid} do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => %{"state" => "paid", "linkGeneration" => 1, "outcome" => "done"}} =
             coordinator
             |> post(intake_path(w, paid.id, "resend-link"), %{})
             |> json_response(200)

    assert %{"data" => %{"linkGeneration" => 2, "outcome" => "done"}} =
             coordinator |> post(intake_path(w, paid.id, "rotate-link")) |> json_response(200)

    assert %{"data" => %{"roster" => %{"seated" => [seated]}}} = console(coordinator, w)
    assert seated["linkGeneration"] == 2
    assert Enum.map(seated["history"], & &1["command"]) == ~w(resend_link rotate_link)
  end

  test "Needs attention lists contacted people unpaid after their window",
       %{conn: conn, workshop: w, contacted: contacted} do
    coordinator = as_role(conn, "beginners_coordinator")
    assert %{"data" => %{"unpaidAfterWindow" => []}} = console(coordinator, w)

    # Move Batch 1 into the past: its window ended an hour ago (wall clock).
    now = DateTime.utc_now()

    Repo.update_all(
      from(b in Dhc.BeginnersWorkshops.Batch, where: b.workshop_id == ^w.id),
      set: [sent_at: DateTime.add(now, -2 * 86_400), window_ends_at: DateTime.add(now, -3_600)]
    )

    assert %{"data" => %{"unpaidAfterWindow" => [unpaid]}} = console(coordinator, w)
    assert %{"id" => id, "batchNumber" => 1, "windowEndsAt" => _} = unpaid
    assert id == contacted.id
  end

  # ALE-387: the payment that paid the fixture's forced-`paid` Intake.
  defp paying_payment!(workshop, intake) do
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

  describe "cancel with refund and withdraw (ALE-387)" do
    test "cancel-with-refund needs beginners.workshops.manage; withdraw beginners.waitlist.manage",
         %{conn: conn, workshop: w, paid: paid} do
      for action <- ~w(cancel-with-refund withdraw) do
        assert conn |> post(intake_path(w, paid.id, action), %{}) |> json_response(401)

        for role <- ~w(coach member),
            do:
              assert(
                conn
                |> as_role(role)
                |> post(intake_path(w, paid.id, action), %{"refund" => true})
                |> json_response(403)
              )
      end

      assert conn
             |> as_role("coach")
             |> post("/api/beginners-workshops/people/#{paid.waitlist_id}/withdraw", %{})
             |> json_response(403)

      assert %Intake{state: "paid"} = Repo.reload!(paid)
    end

    test "cancel-with-refund answers the refunded Intake, then already_done",
         %{conn: conn, workshop: w, paid: paid} do
      paying_payment!(w, paid)
      coordinator = as_role(conn, "beginners_coordinator")

      assert %{"data" => %{"state" => "cancelled_refunded", "outcome" => "done"}} =
               coordinator
               |> post(intake_path(w, paid.id, "cancel-with-refund"), %{"note" => "Asked"})
               |> json_response(200)

      assert [%IntakeRefund{reason: "cancelled_with_refund", amount_cents: 4000}] =
               Repo.all(IntakeRefund)

      assert %{"data" => %{"outcome" => "already_done"}} =
               coordinator
               |> post(intake_path(w, paid.id, "cancel-with-refund"), %{})
               |> json_response(200)

      assert %{"data" => %{"roster" => %{"seated" => [], "out" => [out]}}} =
               console(coordinator, w)

      assert out["state"] == "cancelled_refunded"
      assert out["refund"]["automatic"] == false
      assert [%{"command" => "cancel_with_refund", "note" => "Asked"}] = out["history"]
    end

    test "refusals carry their codes", %{conn: conn, workshop: w, contacted: c, paid: paid} do
      coordinator = as_role(conn, "beginners_coordinator")

      assert %{"errors" => %{"code" => "intake_not_paid"}} =
               coordinator
               |> post(intake_path(w, c.id, "cancel-with-refund"), %{})
               |> json_response(409)

      assert %{"errors" => %{"code" => "nothing_to_refund"}} =
               coordinator
               |> post(intake_path(w, paid.id, "cancel-with-refund"), %{})
               |> json_response(409)

      assert %{"errors" => %{"code" => "refund_choice_required", "fields" => %{"refund" => [_]}}} =
               coordinator |> post(intake_path(w, paid.id, "withdraw"), %{}) |> json_response(422)

      assert %{"errors" => %{"code" => "invalid_refund_choice", "fields" => %{"refund" => [_]}}} =
               coordinator
               |> post(intake_path(w, paid.id, "withdraw"), %{"refund" => "maybe"})
               |> json_response(422)

      assert coordinator
             |> post("/api/beginners-workshops/people/#{Ecto.UUID.generate()}/withdraw", %{})
             |> json_response(404)
    end

    test "withdraw by Intake forfeits or refunds as chosen",
         %{conn: conn, workshop: w, contacted: c, paid: paid} do
      coordinator = as_role(conn, "beginners_coordinator")

      assert %{"data" => %{"state" => "withdrawn", "outcome" => "done"}} =
               coordinator
               |> post(intake_path(w, paid.id, "withdraw"), %{"refund" => false})
               |> json_response(200)

      assert %{"data" => %{"state" => "declined"}} =
               coordinator |> post(intake_path(w, c.id, "withdraw"), %{}) |> json_response(200)

      for intake <- [paid, c],
          do:
            assert(
              %WaitlistEntry{status: "removed"} = Repo.get!(WaitlistEntry, intake.waitlist_id)
            )

      assert Repo.all(IntakeRefund) == []
    end

    test "the Waitlist tab withdraws a person, with or without an Intake",
         %{conn: conn, workshop: w, paid: paid} do
      paying_payment!(w, paid)
      coordinator = as_role(conn, "beginners_coordinator")
      person = BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-05-01 12:00:00Z])

      assert %{
               "data" => %{
                 "status" => "removed",
                 "intake" => nil,
                 "outcome" => "done",
                 "waitlistId" => waitlist_id
               }
             } =
               coordinator
               |> post("/api/beginners-workshops/people/#{person.id}/withdraw", %{})
               |> json_response(200)

      assert waitlist_id == person.id

      assert %{
               "data" => %{
                 "status" => "removed",
                 "intake" => %{"state" => "withdrawn", "outcome" => "done"}
               }
             } =
               coordinator
               |> post("/api/beginners-workshops/people/#{paid.waitlist_id}/withdraw", %{
                 "refund" => true
               })
               |> json_response(200)

      assert [%IntakeRefund{reason: "withdrawn"}] = Repo.all(IntakeRefund)
    end
  end

  describe "correct attendance (ALE-393)" do
    test "needs beginners.workshops.manage", %{conn: conn, workshop: w, paid: paid} do
      assert conn
             |> post(intake_path(w, paid.id, "correct-attendance"), %{"to" => "no_show"})
             |> json_response(401)

      for role <- ~w(coach member),
          do:
            assert(
              conn
              |> as_role(role)
              |> post(intake_path(w, paid.id, "correct-attendance"), %{"to" => "no_show"})
              |> json_response(403)
            )
    end

    test "refuses before finalisation and an unknown target",
         %{conn: conn, workshop: w, paid: paid} do
      coordinator = as_role(conn, "beginners_coordinator")
      BeginnersWorkshopFixtures.force_intake_state!(paid.id, "attended")

      assert %{"errors" => %{"code" => "before_finalisation"}} =
               coordinator
               |> post(intake_path(w, paid.id, "correct-attendance"), %{"to" => "no_show"})
               |> json_response(409)

      assert %{"errors" => %{"code" => "invalid_correction", "fields" => %{"to" => [_]}}} =
               coordinator
               |> post(intake_path(w, paid.id, "correct-attendance"), %{"to" => "paid"})
               |> json_response(422)
    end

    test "corrects a finalised Intake and the console shows it",
         %{conn: conn, workshop: w, paid: paid} do
      coordinator = as_role(conn, "beginners_coordinator")
      BeginnersWorkshopFixtures.force_intake_state!(paid.id, "attended")
      BeginnersWorkshopFixtures.force_status!(w.id, "finalised")

      assert %{"data" => %{"roster" => %{"attended" => [attended]}}} = console(coordinator, w)
      assert "correct_attendance" in attended["availableCommands"]
      assert attended["attendanceCorrections"] == ["no_show"]

      assert %{"data" => %{"state" => "no_show", "outcome" => "done"}} =
               coordinator
               |> post(intake_path(w, paid.id, "correct-attendance"), %{
                 "to" => "no_show",
                 "note" => "Left early"
               })
               |> json_response(200)

      assert %{"data" => %{"roster" => %{"noShow" => [no_show]}}} = console(coordinator, w)
      assert no_show["attendanceCorrections"] == ["attended", "deferred"]

      assert [
               %{
                 "command" => "correct_attendance",
                 "correction" => "no_show",
                 "note" => "Left early"
               }
             ] = no_show["history"]

      assert %{"data" => %{"outcome" => "already_done"}} =
               coordinator
               |> post(intake_path(w, paid.id, "correct-attendance"), %{"to" => "no_show"})
               |> json_response(200)
    end
  end
end
