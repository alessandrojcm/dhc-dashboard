defmodule DhcWeb.BeginnersWorkshopFastTrackControllerTest do
  @moduledoc """
  ALE-384 contract test for the `beginnersWorkshopFastTrack` slice: the
  capability gate, the search, placing a Waitlist person and a new person,
  each refusal's status and code, and the console's `fastTrackOpen` and
  Fast-track origin.
  """
  use DhcWeb.ConnCase, async: false

  import Ecto.Query

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator president coach member)

  setup %{conn: conn} do
    role_subs =
      Map.new(@roles, fn role ->
        member = Dhc.MemberFixtures.member_fixture()

        if role != "member",
          do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

        {role, member.principal_id}
      end)

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    # The HTTP path uses the wall clock: a workshop well ahead of it.
    date = Date.add(ClubCalendar.today(), 60)

    %{"data" => [workshop]} =
      conn
      |> as_role("beginners_coordinator")
      |> post("/api/beginners-workshops", %{
        "workshops" => [
          %{
            "venue" => "St. Andrew's Hall",
            "date" => Date.to_iso8601(date),
            "startTime" => "18:30",
            "capacity" => 2,
            "feeCents" => 4000,
            "contactFromDate" => Date.to_iso8601(Date.add(date, -10))
          }
        ]
      })
      |> json_response(201)

    %{workshop: workshop}
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp ft_path(workshop, suffix \\ ""),
    do: "/api/beginners-workshops/#{workshop["id"]}/fast-track#{suffix}"

  defp new_person(email) do
    %{
      "firstName" => "Ciara",
      "lastName" => "Referral",
      "email" => email,
      "phoneNumber" => "+353 1 000 0000",
      "dateOfBirth" => "1990-03-03",
      "gender" => "woman (cis)",
      "medicalConditions" => ""
    }
  end

  test "only managers search and fast-track", %{conn: conn, workshop: w} do
    person = BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-01-01 12:00:00Z])

    assert conn |> get(ft_path(w, "/candidates")) |> json_response(401)
    assert conn |> post(ft_path(w), %{"waitlistId" => person.id}) |> json_response(401)

    for role <- ~w(coach member) do
      assert conn |> as_role(role) |> get(ft_path(w, "/candidates")) |> json_response(403)

      assert conn
             |> as_role(role)
             |> post(ft_path(w), %{"waitlistId" => person.id})
             |> json_response(403)

      assert conn
             |> as_role(role)
             |> post(ft_path(w, "/new-person"), new_person("x@example.com"))
             |> json_response(403)
    end

    assert conn |> as_role("president") |> get(ft_path(w, "/candidates")) |> json_response(200)
  end

  test "the search lists waiting and recently removed people", %{conn: conn, workshop: w} do
    person =
      BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-01-01 12:00:00Z],
        first_name: "Aoife"
      )

    _other =
      BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-02-01 12:00:00Z],
        first_name: "Bea"
      )

    assert %{"data" => [candidate]} =
             conn
             |> as_role("beginners_coordinator")
             |> get(ft_path(w, "/candidates"), %{"q" => "aoife"})
             |> json_response(200)

    assert candidate == %{
             "waitlistId" => person.id,
             "firstName" => "Aoife",
             "lastName" => "Waiting",
             "email" => person.email,
             "status" => "waiting",
             "removedAt" => nil,
             "minor" => false
           }

    assert conn
           |> as_role("beginners_coordinator")
           |> get("/api/beginners-workshops/#{Ecto.UUID.generate()}/fast-track/candidates")
           |> json_response(404)
  end

  test "a Waitlist person becomes a fast-track Intake on the console", %{conn: conn, workshop: w} do
    person =
      BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-01-01 12:00:00Z],
        first_name: "Aoife"
      )

    coordinator = as_role(conn, "beginners_coordinator")

    assert %{
             "data" => %{
               "intakeId" => intake_id,
               "workshopId" => workshop_id,
               "waitlistId" => waitlist_id,
               "state" => "contacted",
               "origin" => "fast_track",
               "placed" => "waiting",
               "contactedAt" => _
             }
           } = coordinator |> post(ft_path(w), %{"waitlistId" => person.id}) |> json_response(201)

    assert workshop_id == w["id"]
    assert waitlist_id == person.id

    assert %{
             "data" => %{
               "fastTrackOpen" => true,
               "roster" => %{
                 "asked" => [
                   %{
                     "id" => ^intake_id,
                     "origin" => "fast_track",
                     "batchNumber" => nil,
                     "firstName" => "Aoife"
                   }
                 ]
               }
             }
           } =
             coordinator
             |> get("/api/beginners-workshops/#{w["id"]}/console")
             |> json_response(200)

    assert %{"errors" => %{"code" => "open_intake"}} =
             coordinator |> post(ft_path(w), %{"waitlistId" => person.id}) |> json_response(409)
  end

  test "Waitlist refusals", %{conn: conn, workshop: w} do
    coordinator = as_role(conn, "beginners_coordinator")

    attended =
      BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-01-01 12:00:00Z],
        status: "attended"
      )

    assert %{"errors" => %{"code" => "not_eligible"}} =
             coordinator |> post(ft_path(w), %{"waitlistId" => attended.id}) |> json_response(409)

    assert %{"errors" => %{"detail" => "Waitlist person not found"}} =
             coordinator
             |> post(ft_path(w), %{"waitlistId" => Ecto.UUID.generate()})
             |> json_response(404)

    BeginnersWorkshopFixtures.force_status!(w["id"], "cancelled")

    assert %{"errors" => %{"code" => "already_cancelled"}} =
             coordinator |> post(ft_path(w), %{"waitlistId" => attended.id}) |> json_response(409)
  end

  test "a new person is added and fast-tracked, or refused with a visible reason",
       %{conn: conn, workshop: w} do
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => %{"placed" => "added", "origin" => "fast_track"}} =
             coordinator
             |> post(ft_path(w, "/new-person"), new_person("ciara@example.com"))
             |> json_response(201)

    assert %{
             "errors" => %{
               "code" => "email_on_waitlist",
               "fields" => %{"email" => [_]}
             }
           } =
             coordinator
             |> post(ft_path(w, "/new-person"), new_person("ciara@example.com"))
             |> json_response(409)

    {:ok, _} =
      Dhc.Auth.register_principal_with_id(Ecto.UUID.generate(), %{email: "m@example.com"})

    assert %{"errors" => %{"code" => "email_is_principal", "fields" => %{"email" => [_]}}} =
             coordinator
             |> post(ft_path(w, "/new-person"), new_person("m@example.com"))
             |> json_response(409)

    {:ok, _} =
      Dhc.Invitations.Repository.insert_pending_invitation(
        %{"email" => "invited@example.com", "dateOfBirth" => "1990-01-01"},
        nil,
        nil
      )

    assert %{"errors" => %{"code" => "email_has_pending_invitation"}} =
             coordinator
             |> post(ft_path(w, "/new-person"), new_person("invited@example.com"))
             |> json_response(409)

    assert %{"errors" => %{"code" => "invalid_payload"}} =
             coordinator
             |> post(ft_path(w, "/new-person"), %{new_person("y@example.com") | "lastName" => ""})
             |> json_response(422)

    assert %{"errors" => %{"fields" => %{"firstName" => [_]}}} =
             coordinator
             |> post(ft_path(w, "/new-person"), %{
               new_person("z@example.com")
               | "firstName" => String.duplicate("a", 41)
             })
             |> json_response(422)
  end

  test "after the Payment Cutoff Fast-track is refused and not offered", %{
    conn: conn,
    workshop: w
  } do
    Repo.update_all(
      from(b in Dhc.BeginnersWorkshops.BeginnersWorkshop, where: b.id == ^w["id"]),
      set: [payment_cutoff: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    person = BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"errors" => %{"code" => "after_cutoff"}} =
             coordinator |> post(ft_path(w), %{"waitlistId" => person.id}) |> json_response(409)

    assert %{"data" => %{"fastTrackOpen" => false}} =
             coordinator
             |> get("/api/beginners-workshops/#{w["id"]}/console")
             |> json_response(200)
  end
end
