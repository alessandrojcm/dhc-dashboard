defmodule DhcWeb.MemberRolesControllerTest do
  use DhcWeb.ConnCase, async: false

  import Dhc.AuthFixtures
  import Dhc.MemberFixtures
  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{PrincipalToken, Roles, UserRole}
  alias Dhc.Repo

  setup do
    actor = member_fixture()
    target = member_fixture()
    put_roles(actor.principal_id, ["admin", "member"])
    put_roles(target.principal_id, ["member"])
    %{actor: actor.principal_id, target: target.principal_id}
  end

  test "only active admins and presidents can read or edit roles", %{actor: actor, target: id} do
    for role <- Roles.available() do
      put_roles(actor, [role])
      status = if role in ["admin", "president"], do: 200, else: 403
      assert authenticated(actor) |> get("/api/members/#{id}/roles") |> json_response(status)

      assert authenticated(actor)
             |> patch("/api/members/#{id}/roles", %{roles: ["member"], expectedRoles: ["member"]})
             |> json_response(status)
    end

    assert conn() |> get("/api/members/#{id}/roles") |> json_response(401)
    assert conn() |> patch("/api/members/#{id}/roles", %{}) |> json_response(401)
  end

  test "changed roles revoke every target session and socket, not other members", %{
    actor: actor,
    target: id
  } do
    principal = Auth.get_principal!(id)
    first = session_token(principal)
    second = session_token(principal)
    {:ok, socket} = Auth.create_socket_token(principal)
    other = session_token(Auth.get_principal!(actor))
    {login, _} = magic_link_token(principal)
    Phoenix.PubSub.subscribe(Dhc.PubSub, DhcWeb.UserSocket.socket_id(id))

    response =
      authenticated(actor)
      |> patch("/api/members/#{id}/roles", %{
        roles: ["coach", "member"],
        expectedRoles: ["member"]
      })
      |> json_response(200)

    assert response["data"]["roles"] == ["coach", "member"]
    assert Enum.sort(response["data"]["availableRoles"]) == Enum.sort(Roles.available())
    assert {:error, :invalid} = Auth.get_principal_by_session_token(first)
    assert {:error, :invalid} = Auth.get_principal_by_session_token(second)
    assert {:error, :invalid} = Auth.get_principal_by_socket_token(socket)
    assert {:ok, _} = Auth.get_principal_by_session_token(other)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert {:error, :invalid} = Auth.create_socket_token(principal, first)

    # A fresh proof signs in with the new, live capabilities.
    assert {:ok, %{session: %{roles: roles, capabilities: capabilities}}} =
             Auth.consume_magic_link(login)

    assert roles |> Enum.sort() == ["coach", "member"]
    assert "training_announcements.manage" in capabilities
  end

  test "no-op keeps sessions and sends no disconnect", %{actor: actor, target: id} do
    token = session_token(Auth.get_principal!(id))
    Phoenix.PubSub.subscribe(Dhc.PubSub, DhcWeb.UserSocket.socket_id(id))

    assert {:ok, _} =
             Roles.update(actor, id, %{"roles" => ["member"], "expectedRoles" => ["member"]})

    assert {:ok, _} = Auth.get_principal_by_session_token(token)
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
  end

  test "role sets use lexical order, not the PostgreSQL enum declaration order", %{
    actor: actor,
    target: id
  } do
    put_roles(id, ["president", "member"])
    assert {:ok, %{roles: ["member", "president"]}} = Roles.show(actor, id)

    assert {:ok, %{roles: ["member", "treasurer"]}} =
             Roles.update(actor, id, %{
               "roles" => ["treasurer", "member"],
               "expectedRoles" => ["president", "member"]
             })
  end

  test "stale or invalid payloads leave roles and tokens unchanged", %{actor: actor, target: id} do
    token = session_token(Auth.get_principal!(id))

    for payload <- [
          %{roles: ["unknown"], expectedRoles: ["member"]},
          %{roles: ["coach", "coach"], expectedRoles: ["member"]},
          %{roles: "admin", expectedRoles: ["member"]},
          %{roles: ["coach"]},
          %{roles: ["coach"], expectedRoles: ["member"], isActive: true}
        ] do
      assert authenticated(actor)
             |> patch("/api/members/#{id}/roles", payload)
             |> json_response(422)
    end

    response =
      authenticated(actor)
      |> patch("/api/members/#{id}/roles", %{roles: ["coach"], expectedRoles: []})
      |> json_response(409)

    assert response["errors"]["code"] == "roles_changed"
    assert {:ok, %{roles: ["member"]}} = Roles.show(actor, id)
    assert {:ok, _} = Auth.get_principal_by_session_token(token)
  end

  test "can remove all target roles but cannot remove the last active editor", %{
    actor: actor,
    target: id
  } do
    assert {:ok, %{roles: []}} =
             Roles.update(actor, id, %{"roles" => [], "expectedRoles" => ["member"]})

    assert {:error, :last_role_editor} =
             Roles.update(actor, actor, %{
               "roles" => ["member"],
               "expectedRoles" => ["admin", "member"]
             })

    assert {:ok, %{roles: ["admin", "member"]}} = Roles.show(actor, actor)

    put_roles(id, ["president", "member"])

    assert {:ok, %{roles: ["member"]}} =
             Roles.update(actor, actor, %{
               "roles" => ["member"],
               "expectedRoles" => ["admin", "member"]
             })

    assert {:error, :forbidden} = Roles.show(actor, id)
  end

  test "missing and malformed members are 404, inactive actors cannot edit", %{
    actor: actor,
    target: id
  } do
    for missing <- [Ecto.UUID.generate(), "invalid"] do
      assert authenticated(actor) |> get("/api/members/#{missing}/roles") |> json_response(404)
    end

    Repo.update_all(from(p in Dhc.UserProfiles.UserProfile, where: p.principal_id == ^actor),
      set: [is_active: false]
    )

    assert authenticated(actor) |> get("/api/members/#{id}/roles") |> json_response(401)

    assert {:error, :forbidden} =
             Roles.update(actor, id, %{"roles" => [], "expectedRoles" => ["member"]})
  end

  test "role enum agrees with OpenAPI and database" do
    {:ok, spec} =
      :dhc |> Application.app_dir("priv/api/openapi.yaml") |> YamlElixir.read_from_file()

    assert Enum.sort(spec["components"]["schemas"]["ClubRole"]["enum"]) ==
             Enum.sort(Roles.available())

    %{rows: rows} = Repo.query!("SELECT unnest(enum_range(NULL::role_type))::text")
    assert rows |> List.flatten() |> Enum.sort() == Enum.sort(Roles.available())
    assert Repo.aggregate(PrincipalToken, :count) == 0
  end

  defp put_roles(id, roles) do
    Repo.delete_all(from(r in UserRole, where: r.principal_id == ^id))
    Repo.insert_all(UserRole, Enum.map(roles, &%{principal_id: id, role: &1}))
  end

  defp authenticated(id) do
    token = session_token(Auth.get_principal!(id))
    conn = %{conn() | secret_key_base: DhcWeb.Endpoint.config(:secret_key_base)}
    signer = put_resp_cookie(conn, "_dhc_session", token, sign: true)
    put_req_cookie(conn, "_dhc_session", signer.resp_cookies["_dhc_session"].value)
  end
end
