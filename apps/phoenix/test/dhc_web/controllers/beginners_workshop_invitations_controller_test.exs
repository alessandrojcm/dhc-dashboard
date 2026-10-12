defmodule DhcWeb.BeginnersWorkshopInvitationsControllerTest do
  @moduledoc """
  ALE-392 contract test for the `beginnersWorkshopInvitations` slice: the
  `members.invite` gate (which the beginners coordinator now holds), the
  Invitable view's shape, the one-click Invitation, each refusal's status
  and code, and the console's standing and attended · invited · joined line.
  """
  use DhcWeb.ConnCase, async: false

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshops
  alias Dhc.Invitations.Invitation
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator president coach member)
  @during ~U[2026-10-24 10:30:00.000000Z]

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

    coordinator = role_subs["beginners_coordinator"]

    workshop =
      scheduled_fixture(coordinator, %{"date" => "2026-10-24", "start_time" => "11:00"})

    attended = paid_person_fixture!(workshop.id, first_name: "Niamh")
    absent = paid_person_fixture!(workshop.id, first_name: "Oisín")

    {:ok, _} =
      BeginnersWorkshops.execute({:staff, coordinator}, {:check_in, workshop.id, attended.id},
        clock: clock(@during)
      )

    {:ok, _} =
      BeginnersWorkshops.execute({:staff, coordinator}, {:finish_workshop, workshop.id},
        clock: clock(@during)
      )

    %{workshop: workshop, attended: attended, absent: absent}
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp invite_path(ctx, intake),
    do: "/api/beginners-workshops/#{ctx.workshop.id}/intakes/#{intake.id}/invite"

  defp required(schema) do
    {:ok, spec} = YamlElixir.read_from_file(Application.app_dir(:dhc, "priv/api/openapi.yaml"))
    Enum.sort(spec["components"]["schemas"][schema]["required"])
  end

  test "only members.invite holders see the Invitable view and invite", %{conn: conn} = ctx do
    assert conn |> get("/api/beginners-workshops/invitable") |> json_response(401)
    assert conn |> post(invite_path(ctx, ctx.attended)) |> json_response(401)

    for role <- ~w(coach member) do
      assert conn
             |> as_role(role)
             |> get("/api/beginners-workshops/invitable")
             |> json_response(403)

      assert conn |> as_role(role) |> post(invite_path(ctx, ctx.attended)) |> json_response(403)
    end

    for role <- ~w(beginners_coordinator president) do
      assert %{"data" => [_row]} =
               conn
               |> as_role(role)
               |> get("/api/beginners-workshops/invitable")
               |> json_response(200)
    end
  end

  test "the Invitable view lists the attended person in the contract's shape",
       %{conn: conn} = ctx do
    assert %{"data" => [row]} =
             conn
             |> as_role("beginners_coordinator")
             |> get("/api/beginners-workshops/invitable")
             |> json_response(200)

    assert row |> Map.keys() |> Enum.sort() == required("BeginnersWorkshopInvitable")

    assert %{
             "intakeId" => intake_id,
             "workshopId" => workshop_id,
             "workshopDate" => "2026-10-24",
             "firstName" => "Niamh",
             "followUp" => %{"status" => "scheduled", "at" => "2026-10-25T10:00:00Z"}
           } = row

    assert intake_id == ctx.attended.id
    assert workshop_id == ctx.workshop.id
  end

  test "POST /invite issues the Invitation; the person leaves the view until it is deleted",
       %{conn: conn} = ctx do
    assert %{"data" => data} =
             conn
             |> as_role("beginners_coordinator")
             |> post(invite_path(ctx, ctx.attended))
             |> json_response(201)

    assert data |> Map.keys() |> Enum.sort() == required("BeginnersWorkshopInvitation")
    assert %{"standing" => "invited", "invitationId" => invitation_id} = data
    assert %Invitation{waitlist_id: waitlist_id} = Repo.get!(Invitation, invitation_id)
    assert waitlist_id == ctx.attended.waitlist_id

    assert %{"data" => []} =
             conn
             |> as_role("beginners_coordinator")
             |> get("/api/beginners-workshops/invitable")
             |> json_response(200)

    assert %{"errors" => %{"code" => "already_invited"}} =
             conn
             |> as_role("beginners_coordinator")
             |> post(invite_path(ctx, ctx.attended))
             |> json_response(409)

    # The existing Invitations table's delete gives the standing back.
    assert conn
           |> as_role("beginners_coordinator")
           |> delete("/api/invitations", %{"invitationIds" => [invitation_id]})
           |> response(204)

    assert %{"data" => [_back]} =
             conn
             |> as_role("beginners_coordinator")
             |> get("/api/beginners-workshops/invitable")
             |> json_response(200)
  end

  test "refusals carry their status and code", %{conn: conn} = ctx do
    assert %{"errors" => %{"code" => "not_attended"}} =
             conn
             |> as_role("beginners_coordinator")
             |> post(invite_path(ctx, ctx.absent))
             |> json_response(409)

    assert conn
           |> as_role("beginners_coordinator")
           |> post(
             "/api/beginners-workshops/#{ctx.workshop.id}/intakes/#{Ecto.UUID.generate()}/invite"
           )
           |> json_response(404)

    {:ok, _principal} =
      Dhc.Auth.register_principal(%{
        email: Repo.get!(Dhc.Waitlist.WaitlistEntry, ctx.attended.waitlist_id).email
      })

    assert %{"errors" => %{"code" => "email_is_principal"}} =
             conn
             |> as_role("beginners_coordinator")
             |> post(invite_path(ctx, ctx.attended))
             |> json_response(409)
  end

  test "the console carries each person's standing and the invitations line",
       %{conn: conn} = ctx do
    conn
    |> as_role("beginners_coordinator")
    |> post(invite_path(ctx, ctx.attended))
    |> json_response(201)

    assert %{"data" => console} =
             conn
             |> as_role("beginners_coordinator")
             |> get("/api/beginners-workshops/#{ctx.workshop.id}/console")
             |> json_response(200)

    assert console["finalisation"]["invitations"] == %{
             "attended" => 1,
             "invited" => 1,
             "joined" => 0
           }

    assert [%{"standing" => "invited"}] = console["roster"]["attended"]
    assert [%{"standing" => "removed"}] = console["roster"]["noShow"]

    assert console["roster"]["attended"] |> hd() |> Map.keys() |> Enum.sort() ==
             required("BeginnersWorkshopRosterIntake")
  end
end
