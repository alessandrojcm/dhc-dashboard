defmodule DhcWeb.MembersControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  defmodule Verifier do
    @members_admin_roles ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)

    Enum.each(@members_admin_roles, fn role ->
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

    # A token carrying no roles proves the insurance-form endpoint is
    # authenticated-only (no committee role required), mirroring the
    # `settings` SELECT RLS policy.
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

  describe "analytics" do
    test "returns members analytics in the dashboard chart shape, active-only, with unnested weapons",
         %{conn: conn} do
      # Active members.
      insert_member(gender: "man (cis)", age: 20, preferred_weapon: ["longsword"])

      insert_member(
        gender: "woman (cis)",
        age: 30,
        preferred_weapon: ["longsword", "sword_and_buckler"]
      )

      insert_member(gender: "man (cis)", age: 20, preferred_weapon: [])

      # Inactive member — must be excluded from every metric.
      insert_member(gender: "other", age: 50, preferred_weapon: ["longsword"], is_active: false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members/analytics")

      assert %{
               "data" => %{
                 "totalCount" => 3,
                 "averageAge" => average_age,
                 "genderDistribution" => gender_distribution,
                 "ageDistribution" => age_distribution,
                 "weaponDistribution" => weapon_distribution
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

      # The multi-weapon member contributes one count to each of its weapons;
      # the empty-weapon member contributes none; the inactive member is
      # excluded. Raw enum strings are returned (the UI prettifies them).
      assert weapon_distribution == [
               %{"weapon" => "longsword", "value" => 2},
               %{"weapon" => "sword_and_buckler", "value" => 1}
             ]
    end

    test "returns zeroed analytics when there are no active members", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members/analytics")

      assert %{
               "data" => %{
                 "totalCount" => 0,
                 "averageAge" => 0.0,
                 "genderDistribution" => [],
                 "ageDistribution" => [],
                 "weaponDistribution" => []
               }
             } = json_response(conn, 200)
    end

    test "allows all broad committee roles", %{conn: _conn} do
      for role <-
            ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/members/analytics")

        assert %{"data" => %{"totalCount" => 0}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/members/analytics")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks a broad committee role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/members/analytics")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  defp set_insurance_form_link(value) do
    result =
      Repo.query!("UPDATE settings SET value = $1 WHERE key = 'hema_insurance_form_link'", [value])

    assert result.num_rows == 1
  end

  defp insert_member(attrs) do
    today = Date.utc_today()
    date_of_birth = %{today | year: today.year - Keyword.get(attrs, :age, 20)}

    Dhc.MemberFixtures.member_fixture(
      gender: Keyword.get(attrs, :gender, "man (cis)"),
      date_of_birth: date_of_birth,
      preferred_weapon: Keyword.get(attrs, :preferred_weapon, ["longsword"]),
      is_active: Keyword.get(attrs, :is_active, true)
    )
  end
end
