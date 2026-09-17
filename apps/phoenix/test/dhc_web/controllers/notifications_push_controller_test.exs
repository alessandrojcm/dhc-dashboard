defmodule DhcWeb.NotificationsPushControllerTest do
  @moduledoc """
  ALE-299: the browser-facing half of Web Push registration.

  The contract to protect is disclosure: a browser learns whether push is
  configured and the VAPID *public* key, registers or removes *its own*
  subscription, and gets back only an id and timestamp — never an endpoint,
  a browser key, or the private key.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Notifications.PushSubscription
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @user_id "11111111-1111-1111-1111-111111111111"
  @other_user_id "22222222-2222-2222-2222-222222222222"

  setup do
    Dhc.AuthFixtures.principal_fixture(%{id: @user_id})
    Dhc.AuthFixtures.principal_fixture(%{id: @other_user_id})

    original_vapid = Application.get_env(:web_push_ex, :vapid)

    original_verifier =
      OpenApiVerifier.install(
        tokens: %{
          "user-token" => %{sub: @user_id, email: "u@example.com", roles: []},
          "other-user-token" => %{sub: @other_user_id, email: "o@example.com", roles: []}
        }
      )

    on_exit(fn ->
      OpenApiVerifier.restore(original_verifier)
      Application.put_env(:web_push_ex, :vapid, original_vapid)
    end)

    :ok
  end

  describe "GET /api/notifications/push/config" do
    test "requires a session", %{conn: conn} do
      conn = get(conn, "/api/notifications/push/config")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns enabled with the VAPID public key only", %{conn: conn} do
      conn = conn |> as_user() |> get("/api/notifications/push/config")

      public_key = Application.get_env(:web_push_ex, :vapid)[:public_key]

      assert %{"data" => %{"enabled" => true, "vapidPublicKey" => ^public_key} = data} =
               json_response(conn, 200)

      assert Map.keys(data) == ["enabled", "vapidPublicKey"]
      refute inspect(data) =~ Application.get_env(:web_push_ex, :vapid)[:private_key]
    end

    test "reports disabled with a null key when VAPID is not configured", %{conn: conn} do
      Application.delete_env(:web_push_ex, :vapid)

      conn = conn |> as_user() |> get("/api/notifications/push/config")

      assert %{"data" => %{"enabled" => false, "vapidPublicKey" => nil}} =
               json_response(conn, 200)
    end
  end

  describe "POST /api/notifications/push/subscriptions" do
    test "requires a session", %{conn: conn} do
      conn =
        post(
          conn,
          "/api/notifications/push/subscriptions",
          browser_subscription("https://p.example/a")
        )

      assert json_response(conn, 401)
    end

    test "stores the browser subscription for the caller and returns only id and createdAt",
         %{conn: conn} do
      body = browser_subscription("https://p.example/a")

      conn = conn |> as_user() |> post("/api/notifications/push/subscriptions", body)

      assert %{"data" => %{"id" => id, "createdAt" => created_at} = data} =
               json_response(conn, 201)

      assert Map.keys(data) == ["createdAt", "id"]
      assert {:ok, _, _} = DateTime.from_iso8601(created_at)

      assert [%PushSubscription{id: ^id, principal_id: @user_id, user_agent: "Test UA"}] =
               Repo.all(PushSubscription)

      refute json_response(conn, 201) |> inspect() =~ "https://p.example/a"
    end

    test "re-registering the same endpoint answers 201 with the same id", %{conn: conn} do
      body = browser_subscription("https://p.example/a")

      first = conn |> as_user() |> post("/api/notifications/push/subscriptions", body)
      second = conn |> as_user() |> post("/api/notifications/push/subscriptions", body)

      assert %{"data" => %{"id" => id}} = json_response(first, 201)
      assert %{"data" => %{"id" => ^id}} = json_response(second, 201)
      assert [_one] = Repo.all(PushSubscription)
    end

    test "rejects a malformed subscription with 422 and field errors", %{conn: conn} do
      body =
        browser_subscription("http://p.example/plain")
        |> put_in(["keys", "auth"], "short")

      conn = conn |> as_user() |> post("/api/notifications/push/subscriptions", body)

      assert %{"errors" => %{"detail" => detail, "fields" => fields}} = json_response(conn, 422)
      assert detail =~ "endpoint"
      assert %{"endpoint" => [_], "auth" => [_]} = fields
      assert Repo.all(PushSubscription) == []
    end

    test "rejects a body without keys", %{conn: conn} do
      conn =
        conn
        |> as_user()
        |> post("/api/notifications/push/subscriptions", %{"endpoint" => "https://p.example/a"})

      assert %{"errors" => %{"fields" => %{"p256dh" => _, "auth" => _}}} =
               json_response(conn, 422)
    end

    test "does not log the subscription endpoint or keys" do
      filter = Application.get_env(:phoenix, :filter_parameters)

      # Extended the Phoenix 1.8 default rather than replacing it.
      for name <- ["password", "token", "endpoint", "p256dh", "auth", "keys"] do
        assert filter_includes?(filter, name), name
      end

      body = browser_subscription("https://push.example/unique-secret-endpoint")
      filtered = Phoenix.Logger.filter_values(body)

      # The nested `keys` map is discarded wholesale; endpoint is redacted too.
      assert filtered["endpoint"] == "[FILTERED]"
      assert filtered["keys"] == "[FILTERED]"
      refute inspect(filtered) =~ "https://push.example/unique-secret-endpoint"
      refute inspect(filtered) =~ get_in(body, ["keys", "p256dh"])
      refute inspect(filtered) =~ get_in(body, ["keys", "auth"])

      # Those nested names are themselves filter terms, so they redact even
      # if they appear outside the `keys` map.
      assert Phoenix.Logger.filter_values(%{"p256dh" => "secret-p256dh", "auth" => "secret-auth"}) ==
               %{"p256dh" => "[FILTERED]", "auth" => "[FILTERED]"}
    end
  end

  describe "POST /api/notifications/push/unsubscribe" do
    test "removes the caller's subscription and is idempotent", %{conn: conn} do
      conn
      |> as_user()
      |> post(
        "/api/notifications/push/subscriptions",
        browser_subscription("https://p.example/a")
      )

      first =
        conn
        |> as_user()
        |> post("/api/notifications/push/unsubscribe", %{"endpoint" => "https://p.example/a"})

      second =
        conn
        |> as_user()
        |> post("/api/notifications/push/unsubscribe", %{"endpoint" => "https://p.example/a"})

      assert %{"data" => %{"removed" => true}} = json_response(first, 200)
      assert %{"data" => %{"removed" => false}} = json_response(second, 200)
      assert Repo.all(PushSubscription) == []
    end

    test "cannot remove another principal's subscription", %{conn: conn} do
      conn
      |> as_other_user()
      |> post(
        "/api/notifications/push/subscriptions",
        browser_subscription("https://p.example/o")
      )

      conn =
        conn
        |> as_user()
        |> post("/api/notifications/push/unsubscribe", %{"endpoint" => "https://p.example/o"})

      assert %{"data" => %{"removed" => false}} = json_response(conn, 200)
      assert [%PushSubscription{principal_id: @other_user_id}] = Repo.all(PushSubscription)
    end

    test "rejects a missing endpoint", %{conn: conn} do
      conn = conn |> as_user() |> post("/api/notifications/push/unsubscribe", %{})
      assert %{"errors" => %{"detail" => _}} = json_response(conn, 422)
    end
  end

  defp as_user(conn), do: put_req_header(conn, "authorization", "Bearer user-token")
  defp as_other_user(conn), do: put_req_header(conn, "authorization", "Bearer other-user-token")

  # After Phoenix.start the list is compiled to a binary pattern; match the
  # same way `Phoenix.Logger` does so this stays valid either side of compile.
  defp filter_includes?({:compiled, key_match, _value_match}, name),
    do: String.contains?(name, key_match)

  defp filter_includes?(names, name) when is_list(names), do: name in names

  defp browser_subscription(endpoint) do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "endpoint" => endpoint,
      "expirationTime" => nil,
      "keys" => %{
        "p256dh" => Base.url_encode64(public, padding: false),
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      },
      "userAgent" => "Test UA"
    }
  end
end
