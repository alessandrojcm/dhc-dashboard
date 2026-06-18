defmodule DhcWeb.NotificationsControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @user_id "11111111-1111-1111-1111-111111111111"
  @other_user_id "22222222-2222-2222-2222-222222222222"

  defmodule Verifier do
    def verify("user-token") do
      {:ok,
       %{
         sub: "11111111-1111-1111-1111-111111111111",
         email: "user@example.com",
         roles: [],
         raw: %{}
       }}
    end

    def verify("other-user-token") do
      {:ok,
       %{
         sub: "22222222-2222-2222-2222-222222222222",
         email: "other@example.com",
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

  describe "list" do
    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/notifications")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns only the authenticated user's notifications with unread count", %{conn: conn} do
      newer_unread = insert_notification(user_id: @user_id, body: "New unread", seconds: 30)

      older_read =
        insert_notification(user_id: @user_id, body: "Older read", seconds: 10, read?: true)

      insert_notification(user_id: @other_user_id, body: "Other user's unread", seconds: 40)

      conn =
        conn
        |> put_req_header("authorization", "Bearer user-token")
        |> get("/api/notifications")

      assert %{
               "data" => %{
                 "notifications" => [first, second],
                 "unreadCount" => 1,
                 "nextCursor" => nil
               }
             } = json_response(conn, 200)

      assert first == %{
               "id" => newer_unread.id,
               "body" => "New unread",
               "createdAt" => DateTime.to_iso8601(newer_unread.created_at),
               "readAt" => nil
             }

      assert second["id"] == older_read.id
      assert second["body"] == "Older read"
      assert second["createdAt"] == DateTime.to_iso8601(older_read.created_at)
      assert second["readAt"] == DateTime.to_iso8601(older_read.read_at)
      refute Map.has_key?(first, "userId")
      refute Map.has_key?(second, "userId")
    end

    test "supports cursor pagination ordered by createdAt desc with id tie-break", %{conn: conn} do
      shared_created_at = ~U[2026-01-01 12:00:00Z]
      low_id = "00000000-0000-0000-0000-000000000001"
      high_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"

      old_notifications =
        for index <- 1..9 do
          insert_notification(
            user_id: @user_id,
            body: "Old #{index}",
            created_at: DateTime.add(shared_created_at, -index, :second)
          )
        end

      oldest = List.last(old_notifications)

      low =
        insert_notification(
          id: low_id,
          user_id: @user_id,
          body: "Tie low",
          created_at: shared_created_at
        )

      high =
        insert_notification(
          id: high_id,
          user_id: @user_id,
          body: "Tie high",
          created_at: shared_created_at
        )

      first_page =
        conn
        |> put_req_header("authorization", "Bearer user-token")
        |> get("/api/notifications", limit: 10)
        |> json_response(200)

      assert %{
               "data" => %{
                 "notifications" => [%{"id" => ^high_id}, %{"id" => ^low_id} | _],
                 "nextCursor" => next_cursor
               }
             } = first_page

      assert is_binary(next_cursor)
      assert high.id == high_id
      assert low.id == low_id

      second_page =
        build_conn()
        |> put_req_header("authorization", "Bearer user-token")
        |> get("/api/notifications", limit: 10, cursor: next_cursor)
        |> json_response(200)

      assert %{
               "data" => %{
                 "notifications" => [%{"id" => oldest_id}],
                 "unreadCount" => 11,
                 "nextCursor" => nil
               }
             } = second_page

      assert oldest_id == oldest.id
    end

    test "returns 400 for invalid or mismatched cursors", %{conn: conn} do
      invalid_cursor_conn =
        conn
        |> put_req_header("authorization", "Bearer user-token")
        |> get("/api/notifications", cursor: "not-a-cursor")

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(invalid_cursor_conn, 400)

      for index <- 1..11 do
        insert_notification(user_id: @user_id, body: "Notification #{index}", seconds: index)
      end

      cursor =
        build_conn()
        |> put_req_header("authorization", "Bearer user-token")
        |> get("/api/notifications", limit: 10)
        |> json_response(200)
        |> get_in(["data", "nextCursor"])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer user-token")
        |> get("/api/notifications", limit: 25, cursor: cursor)

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(conn, 400)
    end
  end

  defp insert_notification(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    created_at =
      Keyword.get(attrs, :created_at, DateTime.add(now, Keyword.get(attrs, :seconds, 0), :second))

    read_at = if Keyword.get(attrs, :read?, false), do: DateTime.add(created_at, 1, :second)

    %Notification{
      id: Keyword.get(attrs, :id, Ecto.UUID.generate()),
      user_id: Keyword.fetch!(attrs, :user_id),
      body: Keyword.fetch!(attrs, :body),
      created_at: created_at,
      read_at: read_at
    }
    |> Repo.insert!()
  end
end
