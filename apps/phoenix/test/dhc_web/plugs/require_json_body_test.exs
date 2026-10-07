defmodule DhcWeb.Plugs.RequireJsonBodyTest do
  use DhcWeb.ConnCase, async: true

  alias DhcWeb.Plugs.RequireJsonBody

  @detail "Request body must be application/json"

  defp run(method, headers, body \\ "") do
    method
    |> Plug.Test.conn("/api/anything", body)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    end)
    |> RequireJsonBody.call(RequireJsonBody.init([]))
  end

  describe "unsafe methods" do
    test "reject simple-request content types with a 415 problem" do
      for method <- [:post, :put, :patch, :delete],
          content_type <- [
            "application/x-www-form-urlencoded",
            "multipart/form-data; boundary=abc",
            "text/plain",
            "text/plain; charset=utf-8",
            "application/jsonp",
            "nonsense"
          ] do
        conn = run(method, [{"content-type", content_type}], "a=b")

        assert conn.halted, "#{method} #{content_type} should halt"
        assert conn.status == 415

        assert Jason.decode!(conn.resp_body) == %{"errors" => %{"detail" => @detail}}
      end
    end

    test "reject an empty form submission, which still sends a form content type" do
      conn =
        run(:post, [
          {"content-type", "application/x-www-form-urlencoded"},
          {"content-length", "0"}
        ])

      assert conn.halted
      assert conn.status == 415
    end

    test "reject a body without a content type" do
      assert run(:post, [{"content-length", "3"}], "a=b").status == 415
      assert run(:post, [{"transfer-encoding", "chunked"}], "a=b").status == 415
    end

    test "allow JSON and +json bodies" do
      for content_type <- [
            "application/json",
            "application/json; charset=utf-8",
            "Application/JSON",
            "application/merge-patch+json"
          ] do
        conn = run(:post, [{"content-type", content_type}], "{}")
        refute conn.halted, "#{content_type} should pass"
      end
    end

    test "allow bodyless commands" do
      for method <- [:post, :delete] do
        refute run(method, []).halted
        refute run(method, [{"content-length", "0"}]).halted
      end
    end
  end

  test "safe methods are never checked" do
    for method <- [:get, :head, :options] do
      refute run(method, [{"content-type", "text/plain"}]).halted
    end
  end

  describe "through the router" do
    test "a urlencoded form post to the cookie API is refused before the controller",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/api/members/11111111-1111-1111-1111-111111111111/membership/resume", "")

      assert json_response(conn, 415) == %{"errors" => %{"detail" => @detail}}
    end

    test "the magic-link request pipeline refuses a text/plain body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post("/api/auth/magic-link", ~s({"email":"a@example.com"}))

      assert json_response(conn, 415) == %{"errors" => %{"detail" => @detail}}
    end
  end
end
