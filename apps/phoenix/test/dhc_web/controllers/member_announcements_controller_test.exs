defmodule DhcWeb.MemberAnnouncementsControllerTest do
  use DhcWeb.ConnCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.MemberAnnouncements.Workers.DeliveryWorker
  alias Dhc.MemberFixtures
  alias DhcWeb.OpenApiVerifier

  @roles ~w(admin president committee_coordinator member treasurer coach)

  @body %{
    "type" => "doc",
    "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello"}]}]
  }

  setup do
    role_subs = Map.new(@roles, &{&1, Ecto.UUID.generate()})

    for {_role, id} <- role_subs do
      MemberFixtures.member_fixture(principal_id: id, is_active: true)
    end

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)
    :ok
  end

  defp as(role), do: build_conn() |> put_req_header("authorization", "Bearer #{role}-token")

  test "officers preview, send and list", %{conn: _conn} do
    for role <- ~w(admin president committee_coordinator) do
      preview =
        role
        |> as()
        |> post("/api/member-announcements/preview", %{"subject" => "AGM", "body" => @body})
        |> json_response(200)

      assert %{"data" => %{"html" => html, "text" => "Hello", "recipientCount" => 6}} = preview
      assert html =~ "AGM"
    end

    created =
      "president"
      |> as()
      |> post("/api/member-announcements", %{"subject" => "AGM", "body" => @body})
      |> json_response(202)

    assert %{"data" => %{"id" => id, "status" => "queued", "recipientCount" => 6}} = created
    assert_enqueued(worker: DeliveryWorker, args: %{"announcement_id" => id})

    assert %{"data" => [%{"id" => ^id, "sentByName" => "Test Member"}]} =
             "admin" |> as() |> get("/api/member-announcements") |> json_response(200)
  end

  test "every other role is forbidden" do
    for role <- ~w(member treasurer coach) do
      assert "#{role}" |> as() |> get("/api/member-announcements") |> json_response(403)
    end
  end

  test "invalid drafts are field errors" do
    response =
      "admin"
      |> as()
      |> post("/api/member-announcements", %{"subject" => "", "body" => %{"type" => "doc"}})
      |> json_response(422)

    assert %{"errors" => %{"fields" => %{"subject" => [_], "body" => [_]}}} = response
  end
end
