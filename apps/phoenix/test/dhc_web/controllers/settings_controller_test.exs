defmodule DhcWeb.SettingsControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  defmodule Verifier do
    @settings_admin_roles ~w(president committee_coordinator admin)

    Enum.each(@settings_admin_roles, fn role ->
      def verify(unquote("#{role}-token")) do
        {:ok,
         %{
           sub: Ecto.UUID.generate(),
           email: "admin@example.com",
           roles: [unquote(role)],
           raw: %{}
         }}
      end
    end)

    def verify("member-token") do
      {:ok,
       %{sub: Ecto.UUID.generate(), email: "member@example.com", roles: ["member"], raw: %{}}}
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)
  end

  describe "index" do
    test "returns only the allowlisted generic settings", %{conn: conn} do
      # Ensure allowlisted rows have known values, and a non-allowlisted row
      # (waitlist_open) exists so we can assert it is excluded.
      set_setting("hema_insurance_form_link", "https://example.com/insurance")
      set_setting("subscription_max_pause_months", "6")
      set_setting("subscription_min_pause_days", "31")
      set_setting("waitlist_open", "true")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/settings")

      assert %{"data" => %{"settings" => settings}} = json_response(conn, 200)

      keys = Enum.map(settings, & &1["key"])

      assert keys ==
               ~w(hema_insurance_form_link subscription_max_pause_months subscription_min_pause_days)

      refute "waitlist_open" in keys
      refute "stripe_membership_price_ids" in keys

      by_key = Map.new(settings, &{&1["key"], &1})

      assert by_key["hema_insurance_form_link"]["value"] == "https://example.com/insurance"
      assert by_key["subscription_max_pause_months"]["value"] == 6
      assert by_key["subscription_min_pause_days"]["value"] == 31
    end

    test "allows all settings admin roles", %{conn: _conn} do
      for role <- ~w(president committee_coordinator admin) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/settings")

        assert %{"data" => %{"settings" => _}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/settings")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks a settings admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/settings")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  describe "update" do
    test "exposes a single setting version and rejects a stale conditional update", %{conn: conn} do
      path = "/api/settings/subscription_max_pause_months"

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get(path)

      assert %{"data" => %{"lockVersion" => 1}} = json_response(conn, 200)
      assert get_resp_header(conn, "etag") == ["\"1\""]

      {:ok, _} = Dhc.Settings.update("subscription_max_pause_months", 12)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> put_req_header("if-match", "\"1\"")
        |> patch(path, %{"value" => 6})

      assert %{
               "data" => %{"value" => 12, "lockVersion" => 2},
               "errors" => %{"detail" => "version precondition failed"}
             } = json_response(conn, 412)
    end

    test "accepts a matching tag from an If-Match list", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> put_req_header("if-match", "\"1\", \"2\"")
        |> patch("/api/settings/subscription_max_pause_months", %{"value" => 12})

      assert %{"data" => %{"value" => 12, "lockVersion" => 2}} = json_response(conn, 200)
    end

    test "rejects If-None-Match instead of ignoring it", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> put_req_header("if-none-match", "\"1\"")
        |> patch("/api/settings/subscription_max_pause_months", %{"value" => 12})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 400)
      assert detail =~ "If-None-Match"
    end

    test "updates hema_insurance_form_link with a valid URL", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/hema_insurance_form_link", %{
          "value" => "https://new.example.com/form"
        })

      assert %{
               "data" => %{
                 "key" => "hema_insurance_form_link",
                 "value" => "https://new.example.com/form"
               }
             } =
               json_response(conn, 200)

      assert get_setting("hema_insurance_form_link") == "https://new.example.com/form"
    end

    test "updates subscription_max_pause_months with an integer", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer president-token")
        |> patch("/api/settings/subscription_max_pause_months", %{"value" => 12})

      assert %{"data" => %{"key" => "subscription_max_pause_months", "value" => 12}} =
               json_response(conn, 200)

      assert get_setting("subscription_max_pause_months") == "12"
    end

    test "coerces string integers for integer-typed keys", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/subscription_min_pause_days", %{"value" => "45"})

      assert %{"data" => %{"key" => "subscription_min_pause_days", "value" => 45}} =
               json_response(conn, 200)

      assert get_setting("subscription_min_pause_days") == "45"
    end

    test "allows all settings admin roles", %{conn: _conn} do
      for role <- ~w(president committee_coordinator admin) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> patch("/api/settings/subscription_max_pause_months", %{"value" => 6})

        assert %{"data" => %{"key" => "subscription_max_pause_months"}} =
                 json_response(conn, 200)
      end
    end

    test "returns 404 for a non-allowlisted key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/waitlist_open", %{"value" => "true"})

      assert %{"errors" => %{"detail" => "Unknown or non-allowlisted setting key"}} =
               json_response(conn, 404)

      # The non-allowlisted row must not have been mutated.
      assert get_setting("waitlist_open") == "false"
    end

    test "returns 404 for an unknown key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/does_not_exist", %{"value" => "x"})

      assert %{"errors" => %{"detail" => "Unknown or non-allowlisted setting key"}} =
               json_response(conn, 404)
    end

    test "returns 422 for an empty insurance form link", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/hema_insurance_form_link", %{"value" => ""})

      assert %{"errors" => %{"detail" => "must be a non-empty URL"}} = json_response(conn, 422)
    end

    test "returns 422 for a non-URL insurance form link", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/hema_insurance_form_link", %{"value" => "not-a-url"})

      assert %{"errors" => %{"detail" => "must be an http or https URL"}} =
               json_response(conn, 422)
    end

    test "returns 422 for subscription_max_pause_months below range", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/subscription_max_pause_months", %{"value" => 0})

      assert %{"errors" => %{"detail" => "must be at least 1"}} = json_response(conn, 422)
    end

    test "returns 422 for subscription_max_pause_months above range", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/subscription_max_pause_months", %{"value" => 25})

      assert %{"errors" => %{"detail" => "must be at most 24"}} = json_response(conn, 422)
    end

    test "returns 422 for subscription_min_pause_days above range", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/subscription_min_pause_days", %{"value" => 366})

      assert %{"errors" => %{"detail" => "must be at most 365"}} = json_response(conn, 422)
    end

    test "returns 422 for subscription_min_pause_days below range", %{conn: _conn} do
      # Unlike max_pause_months, the min_pause_days below-range branch was
      # previously untested — a regression that dropped the `n < 1` guard
      # would let `0` through and silently disable the minimum pause window.
      for value <- [0, -1] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer admin-token")
          |> patch("/api/settings/subscription_min_pause_days", %{"value" => value})

        assert %{"errors" => %{"detail" => "must be at least 1"}} = json_response(conn, 422)
      end
    end

    test "returns 422 for a non-integer integer-typed value", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/subscription_max_pause_months", %{"value" => "abc"})

      assert %{"errors" => %{"detail" => "must be an integer"}} = json_response(conn, 422)
    end

    test "returns 422 for a float value to an integer-typed key", %{conn: conn} do
      # String-integer coercion is tested, but floats were not — a regression
      # that widened coerce_value to accept floats (or truncated them to int)
      # would let 12.5 silently become 12. A float bypasses the is_binary
      # coerce clause, then fails the is_integer validate guard, surfacing as
      # "invalid value type" (422) rather than being stored or truncated.
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/subscription_max_pause_months", %{"value" => 12.5})

      assert %{"errors" => %{"detail" => "invalid value type"}} = json_response(conn, 422)

      # The stored value must be untouched — no silent truncation persisted.
      refute get_setting("subscription_max_pause_months") == "12"
    end

    test "returns 422 when value is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/settings/hema_insurance_form_link", %{})

      assert %{"errors" => %{"detail" => "value is required"}} = json_response(conn, 422)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn =
        patch(conn, "/api/settings/hema_insurance_form_link", %{
          "value" => "https://x.example.com"
        })

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks a settings admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> patch("/api/settings/hema_insurance_form_link", %{"value" => "https://x.example.com"})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  defp set_setting(key, value) do
    result = Repo.query!("UPDATE settings SET value = $1 WHERE key = $2", [value, key])
    assert result.num_rows == 1
  end

  defp get_setting(key) do
    %{rows: [[value]]} = Repo.query!("SELECT value FROM settings WHERE key = $1", [key])
    value
  end
end
