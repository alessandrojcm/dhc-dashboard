defmodule DhcWeb.MembersControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  defmodule Verifier do
    @doc """
    A token carrying no roles proves the endpoint is authenticated-only
    (no committee role required), mirroring the `settings` SELECT RLS policy.
    """
    def verify("member-token") do
      {:ok,
       %{
         sub: Ecto.UUID.generate(),
         email: "member@example.com",
         roles: [],
         raw: %{}
       }}
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)
  end

  describe "insurance_form" do
    test "returns the configured insurance form link", %{conn: conn} do
      set_insurance_form_link("https://example.com/hema-insurance")

      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/members/insurance-form")

      assert %{"data" => %{"link" => "https://example.com/hema-insurance"}} =
               json_response(conn, 200)
    end

    test "returns a null link when the setting is empty", %{conn: conn} do
      set_insurance_form_link("")

      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/members/insurance-form")

      assert %{"data" => %{"link" => nil}} = json_response(conn, 200)
    end

    test "allows any authenticated user without a committee role", %{conn: conn} do
      set_insurance_form_link("https://example.com/hema-insurance")

      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/members/insurance-form")

      assert %{"data" => %{"link" => _}} = json_response(conn, 200)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/members/insurance-form")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 with an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> get("/api/members/insurance-form")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  defp set_insurance_form_link(value) do
    result =
      Repo.query!("UPDATE settings SET value = $1 WHERE key = 'hema_insurance_form_link'", [value])

    assert result.num_rows == 1
  end
end
