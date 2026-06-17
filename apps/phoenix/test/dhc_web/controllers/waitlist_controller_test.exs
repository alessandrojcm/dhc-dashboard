defmodule DhcWeb.WaitlistControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

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

  defp set_waitlist_open(open?) do
    value = if open?, do: "true", else: "false"
    result = Repo.query!("UPDATE settings SET value = $1 WHERE key = 'waitlist_open'", [value])
    assert result.num_rows == 1
  end

  defp insert_waitlist_profile(attrs) do
    waitlist_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()
    dumped_waitlist_id = Ecto.UUID.dump!(waitlist_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    today = Date.utc_today()
    date_of_birth = %{today | year: today.year - Keyword.fetch!(attrs, :age)}

    {1, _} =
      Repo.insert_all("waitlist", [
        %{
          id: dumped_waitlist_id,
          email: "#{waitlist_id}@example.com",
          status: Keyword.fetch!(attrs, :status),
          initial_registration_date: now,
          last_status_change: now
        }
      ])

    {1, _} =
      Repo.insert_all("user_profiles", [
        %{
          id: Ecto.UUID.dump!(profile_id),
          first_name: "Test",
          last_name: "Waitlist",
          is_active: false,
          date_of_birth: date_of_birth,
          gender: Keyword.fetch!(attrs, :gender),
          phone_number: "+353 1 000 0000",
          waitlist_id: dumped_waitlist_id,
          created_at: now,
          updated_at: now
        }
      ])

    waitlist_id
  end
end
