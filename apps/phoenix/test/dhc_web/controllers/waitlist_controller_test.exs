defmodule DhcWeb.WaitlistControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  defmodule Verifier do
    @waitlist_admin_roles ~w(admin president committee_coordinator beginners_coordinator coach)

    Enum.each(@waitlist_admin_roles, fn role ->
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
    test "returns open status", %{conn: conn} do
      set_waitlist_open(true)

      conn = get(conn, "/api/waitlist/status")

      assert %{"data" => %{"isOpen" => true}} = json_response(conn, 200)
    end

    test "returns closed status", %{conn: conn} do
      set_waitlist_open(false)

      conn = get(conn, "/api/waitlist/status")

      assert %{"data" => %{"isOpen" => false}} = json_response(conn, 200)
    end
  end

  describe "analytics" do
    test "returns waitlist analytics in the dashboard chart shape", %{conn: conn} do
      insert_waitlist_profile(status: "waiting", gender: "man (cis)", age: 20)
      insert_waitlist_profile(status: "invited", gender: "woman (cis)", age: 30)
      insert_waitlist_profile(status: "waiting", gender: "man (cis)", age: 20)
      insert_waitlist_profile(status: "joined", gender: "other", age: 50)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/analytics")

      assert %{
               "data" => %{
                 "totalCount" => 3,
                 "averageAge" => average_age,
                 "genderDistribution" => gender_distribution,
                 "ageDistribution" => age_distribution
               }
             } = json_response(conn, 200)

      assert_in_delta average_age, 23.33, 0.01

      assert gender_distribution == [
               %{"gender" => "man (cis)", "value" => 2},
               %{"gender" => "woman (cis)", "value" => 1}
             ]

      assert age_distribution == [
               %{"age" => 20, "value" => 2},
               %{"age" => 30, "value" => 1}
             ]
    end

    test "allows all waitlist admin roles", %{conn: _conn} do
      for role <- ~w(admin president committee_coordinator beginners_coordinator coach) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/waitlist/analytics")

        assert %{"data" => %{"totalCount" => 0}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/waitlist/analytics")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks a waitlist admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/waitlist/analytics")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  describe "entries" do
    test "allows all waitlist admin roles", %{conn: _conn} do
      for role <- ~w(admin president committee_coordinator beginners_coordinator coach) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/waitlist/entries")

        assert %{"data" => %{"entries" => [], "totalCount" => 0}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/waitlist/entries")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks a waitlist admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/waitlist/entries")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns camelCase entries and excludes joined by default", %{conn: conn} do
      insert_waitlist_profile(
        status: "waiting",
        first_name: "Ada",
        last_name: "Lovelace",
        age: 20
      )

      insert_waitlist_profile(status: "joined", first_name: "Grace", last_name: "Hopper", age: 30)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries")

      assert %{"data" => %{"entries" => [entry], "totalCount" => 1, "limit" => 10}} =
               json_response(conn, 200)

      assert entry["fullName"] == "Ada Lovelace"
      assert entry["phoneNumber"] == "+353 1 000 0000"
      assert entry["medicalConditions"] == "None"
      assert entry["adminNotes"] == "Initial note"
      assert entry["guardianFirstName"] == "Parent"
      assert entry["insuranceFormSubmitted"] == false
      refute Map.has_key?(entry, "searchText")
    end

    test "supports explicit joined status filter", %{conn: conn} do
      insert_waitlist_profile(status: "waiting", first_name: "Ada", last_name: "Lovelace")
      insert_waitlist_profile(status: "joined", first_name: "Grace", last_name: "Hopper")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", status: "joined")

      assert %{"data" => %{"entries" => [%{"status" => "joined"}], "totalCount" => 1}} =
               json_response(conn, 200)
    end

    test "supports cursor next and previous pagination", %{conn: conn} do
      for index <- 1..11 do
        insert_waitlist_profile(
          first_name: "Person#{String.pad_leading(to_string(index), 2, "0")}",
          last_name: "Waitlist",
          seconds: index
        )
      end

      first_page =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", limit: 10)
        |> json_response(200)

      assert %{
               "data" => %{
                 "entries" => first_entries,
                 "nextCursor" => next_cursor,
                 "previousCursor" => nil,
                 "totalCount" => 11
               }
             } = first_page

      assert [%{"fullName" => "Person01 Waitlist"} | _] = first_entries
      assert List.last(first_entries)["fullName"] == "Person10 Waitlist"
      assert is_binary(next_cursor)

      second_page =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", limit: 10, cursor: next_cursor)
        |> json_response(200)

      assert %{
               "data" => %{
                 "entries" => [%{"fullName" => "Person11 Waitlist"}],
                 "nextCursor" => nil,
                 "previousCursor" => back_cursor
               }
             } = second_page

      back_page =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", limit: 10, cursor: back_cursor)
        |> json_response(200)

      assert %{
               "data" => %{
                 "entries" => back_entries,
                 "previousCursor" => nil,
                 "nextCursor" => forward_cursor
               }
             } = back_page

      assert [%{"fullName" => "Person01 Waitlist"} | _] = back_entries
      assert List.last(back_entries)["fullName"] == "Person10 Waitlist"
      assert is_binary(forward_cursor)
    end

    test "supports sorting by allowed fields", %{conn: conn} do
      insert_waitlist_profile(first_name: "Older", last_name: "Person", age: 40)
      insert_waitlist_profile(first_name: "Younger", last_name: "Person", age: 20)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", sort: "age", direction: "asc")

      assert %{"data" => %{"entries" => [%{"age" => 20}, %{"age" => 40}]}} =
               json_response(conn, 200)
    end

    test "supports websearch text search", %{conn: conn} do
      insert_waitlist_profile(first_name: "Needle", last_name: "Person")
      insert_waitlist_profile(first_name: "Haystack", last_name: "Person")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", q: "Needle")

      assert %{"data" => %{"entries" => [%{"fullName" => "Needle Person"}], "totalCount" => 1}} =
               json_response(conn, 200)
    end

    test "returns 400 for invalid or mismatched cursors", %{conn: conn} do
      invalid_cursor_conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", cursor: "not-a-cursor")

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(invalid_cursor_conn, 400)

      for index <- 1..11 do
        insert_waitlist_profile(
          first_name: "Person#{String.pad_leading(to_string(index), 2, "0")}",
          last_name: "Waitlist",
          seconds: index
        )
      end

      cursor =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", limit: 10)
        |> json_response(200)
        |> get_in(["data", "nextCursor"])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", limit: 25, cursor: cursor)

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(conn, 400)
    end
  end

  defp set_waitlist_open(open?) do
    value = if open?, do: "true", else: "false"
    result = Repo.query!("UPDATE settings SET value = $1 WHERE key = 'waitlist_open'", [value])
    assert result.num_rows == 1
  end

  defp insert_waitlist_profile(attrs) do
    waitlist_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    registration_date = DateTime.add(now, Keyword.get(attrs, :seconds, 0), :second)
    today = Date.utc_today()
    date_of_birth = %{today | year: today.year - Keyword.get(attrs, :age, 20)}

    # waitlist via the WaitlistEntry schema — Ecto autodumps the :binary_id PK.
    {:ok, _waitlist} =
      %WaitlistEntry{
        id: waitlist_id,
        email: "#{waitlist_id}@example.com",
        status: Keyword.get(attrs, :status, "waiting"),
        initial_registration_date: registration_date,
        last_contacted: Keyword.get(attrs, :last_contacted),
        last_status_change: registration_date,
        admin_notes: "Initial note"
      }
      |> Repo.insert()

    # user_profiles via the UserProfile schema — Ecto handles the `created_at`
    # timestamp mapping and autodumps the :binary_id PK/FKs. `search_text` is a
    # generated column (not a schema field), so Postgres auto-populates it from
    # first_name/last_name — the websearch tests rely on this.
    {:ok, _profile} =
      %UserProfile{
        id: profile_id,
        first_name: Keyword.get(attrs, :first_name, "Test"),
        last_name: Keyword.get(attrs, :last_name, "Waitlist"),
        is_active: false,
        date_of_birth: date_of_birth,
        gender: Keyword.get(attrs, :gender, "man (cis)"),
        medical_conditions: "None",
        phone_number: "+353 1 000 0000",
        social_media_consent: "no",
        waitlist_id: waitlist_id
      }
      |> Repo.insert()

    # waitlist_guardians has no Ecto schema; insert raw. Postgrex expects
    # binary UUIDs when bypassing the schema.
    {1, _} =
      Repo.insert_all("waitlist_guardians", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          profile_id: Ecto.UUID.dump!(profile_id),
          first_name: "Parent",
          last_name: "Guardian",
          phone_number: "+353 1 111 1111",
          created_at: now
        }
      ])

    waitlist_id
  end
end
