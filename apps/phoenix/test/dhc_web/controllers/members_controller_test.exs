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

    def verify("self-token") do
      {:ok,
       %{
         sub: "11111111-1111-1111-1111-111111111111",
         email: "self@example.com",
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

  describe "index" do
    @members_admin_roles ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)

    test "allows all broad committee roles", %{conn: _conn} do
      for role <- @members_admin_roles do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/members")

        assert %{"data" => %{"members" => [], "totalCount" => 0}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/members")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks a broad committee role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/members")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns camelCase members and excludes internal/leaky fields", %{conn: conn} do
      insert_member(first_name: "Ada", last_name: "Lovelace")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members")

      assert %{"data" => %{"members" => [member], "totalCount" => 1, "limit" => 10}} =
               json_response(conn, 200)

      assert member["firstName"] == "Ada"
      assert member["lastName"] == "Lovelace"
      assert is_binary(member["email"])
      assert member["membershipStatus"] == "active"
      assert member["isActive"] == true
      assert member["preferredWeapon"] == ["longsword"]
      assert member["nextOfKinName"] == "Next of Kin"
      assert member["guardianFirstName"] == nil

      # Internal/leaky fields are not exposed.
      refute Map.has_key?(member, "searchText")
      refute Map.has_key?(member, "userProfileId")
      refute Map.has_key?(member, "createdAt")
      refute Map.has_key?(member, "updatedAt")
      refute Map.has_key?(member, "roles")
      refute Map.has_key?(member, "additionalData")
      refute Map.has_key?(member, "fromWaitlistId")
      refute Map.has_key?(member, "waitlistRegistrationDate")
    end

    test "computes membershipStatus: active/inactive/paused distinct from isActive", %{conn: conn} do
      insert_member(first_name: "Active", last_name: "Member", is_active: true)

      insert_member(first_name: "Inactive", last_name: "Member", is_active: false)

      future = DateTime.add(DateTime.utc_now(), 60 * 60 * 24 * 7, :second)

      insert_member(
        first_name: "Paused",
        last_name: "Member",
        is_active: true,
        subscription_paused_until: future
      )

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", sort: "lastName", direction: "asc")

      assert %{"data" => %{"members" => members}} = json_response(conn, 200)

      statuses =
        members
        |> Enum.map(fn m -> {m["firstName"], m["isActive"], m["membershipStatus"]} end)

      # A paused member has isActive: true, membershipStatus: "paused".
      assert {"Active", true, "active"} in statuses
      assert {"Inactive", false, "inactive"} in statuses
      assert {"Paused", true, "paused"} in statuses
    end

    test "supports cursor next and previous pagination", %{conn: conn} do
      for index <- 1..11 do
        suffix = String.pad_leading(to_string(index), 2, "0")
        insert_member(first_name: "Person#{suffix}", last_name: "Member#{suffix}")
      end

      first_page =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", limit: 10)
        |> json_response(200)

      assert %{
               "data" => %{
                 "members" => first_members,
                 "nextCursor" => next_cursor,
                 "previousCursor" => nil,
                 "totalCount" => 11
               }
             } = first_page

      assert [%{"firstName" => "Person01", "lastName" => "Member01"} | _] = first_members
      assert List.last(first_members)["firstName"] == "Person10"
      assert is_binary(next_cursor)

      second_page =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", limit: 10, cursor: next_cursor)
        |> json_response(200)

      assert %{
               "data" => %{
                 "members" => [%{"firstName" => "Person11"}],
                 "nextCursor" => nil,
                 "previousCursor" => back_cursor
               }
             } = second_page

      back_page =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", limit: 10, cursor: back_cursor)
        |> json_response(200)

      assert %{
               "data" => %{
                 "members" => back_members,
                 "previousCursor" => nil,
                 "nextCursor" => _forward_cursor
               }
             } = back_page

      assert [%{"firstName" => "Person01"} | _] = back_members
      assert List.last(back_members)["firstName"] == "Person10"
    end

    test "supports sorting by allowed fields asc and desc", %{conn: conn} do
      insert_member(first_name: "Zoe", last_name: "Alpha")
      insert_member(first_name: "Amy", last_name: "Beta")

      asc =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", sort: "firstName", direction: "asc")
        |> json_response(200)

      assert %{"data" => %{"members" => [%{"firstName" => "Amy"}, %{"firstName" => "Zoe"}]}} = asc

      desc =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", sort: "firstName", direction: "desc")
        |> json_response(200)

      assert %{"data" => %{"members" => [%{"firstName" => "Zoe"}, %{"firstName" => "Amy"}]}} =
               desc
    end

    test "supports websearch text search", %{conn: conn} do
      insert_member(first_name: "Needle", last_name: "Person")
      insert_member(first_name: "Haystack", last_name: "Person")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", q: "Needle")

      assert %{"data" => %{"members" => [%{"firstName" => "Needle"}], "totalCount" => 1}} =
               json_response(conn, 200)
    end

    test "supports multi-select membershipStatus filter (single and multiple)", %{conn: conn} do
      insert_member(first_name: "Active", last_name: "Member", is_active: true)
      insert_member(first_name: "Inactive", last_name: "Member", is_active: false)
      future = DateTime.add(DateTime.utc_now(), 60 * 60 * 24 * 7, :second)

      insert_member(
        first_name: "Paused",
        last_name: "Member",
        is_active: true,
        subscription_paused_until: future
      )

      # Single status filter
      single =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", membershipStatus: "inactive")
        |> json_response(200)

      assert %{"data" => %{"members" => [%{"firstName" => "Inactive"}], "totalCount" => 1}} =
               single

      # Multiple statuses
      multi =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", membershipStatus: "active,paused")
        |> json_response(200)

      names =
        multi["data"]["members"]
        |> Enum.map(& &1["firstName"])
        |> Enum.sort()

      assert names == ["Active", "Paused"]
    end

    test "absent or empty membershipStatus returns all statuses", %{conn: conn} do
      insert_member(first_name: "Active", last_name: "Member", is_active: true)
      insert_member(first_name: "Inactive", last_name: "Member", is_active: false)

      absent =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members")
        |> json_response(200)

      assert %{"data" => %{"totalCount" => 2}} = absent

      empty =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", membershipStatus: "")
        |> json_response(200)

      assert %{"data" => %{"totalCount" => 2}} = empty
    end

    test "defaults sort to lastName asc", %{conn: conn} do
      insert_member(first_name: "Zed", last_name: "Beta")
      insert_member(first_name: "Amy", last_name: "Alpha")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members")
        |> json_response(200)

      assert %{"data" => %{"members" => [%{"lastName" => "Alpha"}, %{"lastName" => "Beta"}]}} =
               conn
    end

    test "returns 400 for invalid or mismatched cursors", %{conn: conn} do
      invalid =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", cursor: "not-a-cursor")

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(invalid, 400)

      for index <- 1..11 do
        suffix = String.pad_leading(to_string(index), 2, "0")
        insert_member(first_name: "Person#{suffix}", last_name: "Member#{suffix}")
      end

      cursor =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", limit: 10)
        |> json_response(200)
        |> get_in(["data", "nextCursor"])

      mismatched =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members", limit: 25, cursor: cursor)

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(mismatched, 400)
    end
  end

  describe "show" do
    test "allows a member to read their own profile without a committee role", %{conn: conn} do
      insert_member(
        auth_user_id: "11111111-1111-1111-1111-111111111111",
        email: "self@example.com",
        first_name: "Self",
        last_name: "Member"
      )

      conn =
        conn
        |> put_req_header("authorization", "Bearer self-token")
        |> get("/api/members/11111111-1111-1111-1111-111111111111")

      assert %{"data" => member} = json_response(conn, 200)
      assert member["id"] == "11111111-1111-1111-1111-111111111111"
      assert member["firstName"] == "Self"
      assert member["email"] == "self@example.com"
      assert member["dateOfBirth"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
    end

    test "allows broad committee roles to read any member", %{conn: conn} do
      %{auth_user_id: member_id} = insert_member(first_name: "Any", last_name: "Member")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members/#{member_id}")

      assert %{"data" => %{"firstName" => "Any"}} = json_response(conn, 200)
    end

    test "returns 403 when a non-admin reads another member", %{conn: conn} do
      %{auth_user_id: member_id} = insert_member([])

      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/members/#{member_id}")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 404 for an unknown member visible to an admin", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members/22222222-2222-2222-2222-222222222222")

      assert %{"errors" => %{"detail" => "Member not found"}} = json_response(conn, 404)
    end
  end

  describe "update" do
    test "partially updates member profile facts and returns the full member", %{conn: conn} do
      member_id = "11111111-1111-1111-1111-111111111111"

      insert_member(
        auth_user_id: member_id,
        first_name: "Before",
        last_name: "Member",
        phone_number: "+353811111111",
        preferred_weapon: ["longsword"],
        customer_id: nil
      )

      conn =
        conn
        |> put_req_header("authorization", "Bearer self-token")
        |> patch("/api/members/#{member_id}", %{
          "firstName" => "After",
          "phoneNumber" => "+353822222222",
          "dateOfBirth" => "1992-03-04",
          "medicalConditions" => nil,
          "nextOfKinName" => "Emergency Contact",
          "preferredWeapon" => ["sword_and_buckler"],
          "insuranceFormSubmitted" => true,
          "socialMediaConsent" => "yes_unrecognizable"
        })

      assert %{"data" => member} = json_response(conn, 200)
      assert member["firstName"] == "After"
      assert member["lastName"] == "Member"
      assert member["phoneNumber"] == "+353822222222"
      assert member["dateOfBirth"] == "1992-03-04"
      assert member["medicalConditions"] == nil
      assert member["nextOfKinName"] == "Emergency Contact"
      assert member["preferredWeapon"] == ["sword_and_buckler"]
      assert member["insuranceFormSubmitted"] == true
      assert member["socialMediaConsent"] == "yes_unrecognizable"
      assert member["isActive"] == true
    end

    test "allows an admin to update another member", %{conn: conn} do
      %{auth_user_id: member_id} = insert_member(first_name: "Before", customer_id: nil)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/members/#{member_id}", %{"firstName" => "AdminUpdated"})

      assert %{"data" => %{"firstName" => "AdminUpdated"}} = json_response(conn, 200)
    end

    test "rejects attempts to write isActive", %{conn: conn} do
      member_id = "11111111-1111-1111-1111-111111111111"
      insert_member(auth_user_id: member_id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer self-token")
        |> patch("/api/members/#{member_id}", %{"isActive" => false})

      assert %{"errors" => %{"detail" => "Invalid member update payload"}} =
               json_response(conn, 422)
    end

    test "returns 403 when a non-admin updates another member", %{conn: conn} do
      %{auth_user_id: member_id} = insert_member([])

      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> patch("/api/members/#{member_id}", %{"firstName" => "Nope"})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "updates preferredWeapon with multiple weapon types", %{conn: conn} do
      member_id = "11111111-1111-1111-1111-111111111111"

      insert_member(
        auth_user_id: member_id,
        preferred_weapon: ["longsword"],
        customer_id: nil
      )

      conn =
        conn
        |> put_req_header("authorization", "Bearer self-token")
        |> patch("/api/members/#{member_id}", %{
          "preferredWeapon" => ["longsword", "sword_and_buckler"]
        })

      assert %{"data" => member} = json_response(conn, 200)
      assert member["preferredWeapon"] == ["longsword", "sword_and_buckler"]
    end

    test "rejects an invalid preferred_weapon enum value", %{conn: conn} do
      member_id = "11111111-1111-1111-1111-111111111111"

      insert_member(auth_user_id: member_id, customer_id: nil)

      conn =
        conn
        |> put_req_header("authorization", "Bearer self-token")
        |> patch("/api/members/#{member_id}", %{
          "preferredWeapon" => ["lightsaber"]
        })

      assert %{"errors" => %{"detail" => "Invalid member update payload"}} =
               json_response(conn, 422)
    end
  end

  describe "membership pause/resume" do
    setup do
      bypass = Bypass.open()
      original_url = Application.get_env(:dhc, :stripe_api_url)
      original_key = Application.get_env(:dhc, :stripe_secret_key)

      Application.put_env(:dhc, :stripe_api_url, "http://localhost:#{bypass.port}")
      Application.put_env(:dhc, :stripe_secret_key, "sk_test_123")

      on_exit(fn ->
        Application.put_env(:dhc, :stripe_api_url, original_url)
        Application.put_env(:dhc, :stripe_secret_key, original_key)
      end)

      {:ok, bypass: bypass}
    end

    test "pauses a member subscription after Stripe confirms", %{conn: conn, bypass: bypass} do
      member_id = "11111111-1111-1111-1111-111111111111"
      insert_member(auth_user_id: member_id, customer_id: "cus_pause")
      pause_until = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      expect_subscription_list(bypass, "cus_pause", [active_membership_subscription()])

      Bypass.expect(bypass, "POST", "/v1/subscriptions/sub_membership", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["pause_collection[behavior]"] == "void"
        assert params["pause_collection[resumes_at]"] == to_string(DateTime.to_unix(pause_until))

        stripe_json(conn, %{
          "id" => "sub_membership",
          "pause_collection" => %{
            "behavior" => "void",
            "resumes_at" => DateTime.to_unix(pause_until)
          }
        })
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer self-token")
        |> post("/api/members/#{member_id}/membership/pause", %{
          "pauseUntil" => DateTime.to_iso8601(pause_until)
        })

      assert %{"data" => member} = json_response(conn, 200)
      assert member["subscriptionPausedUntil"] == DateTime.to_iso8601(pause_until)
      assert member["membershipStatus"] == "paused"
    end

    test "resumes a paused member subscription after Stripe confirms", %{
      conn: conn,
      bypass: bypass
    } do
      member_id = "11111111-1111-1111-1111-111111111111"
      paused_until = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      insert_member(
        auth_user_id: member_id,
        customer_id: "cus_resume",
        subscription_paused_until: paused_until
      )

      expect_subscription_list(bypass, "cus_resume", [paused_membership_subscription()])

      Bypass.expect(bypass, "POST", "/v1/subscriptions/sub_membership", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["pause_collection"] == ""

        stripe_json(conn, %{"id" => "sub_membership", "pause_collection" => nil})
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer self-token")
        |> post("/api/members/#{member_id}/membership/resume")

      assert %{"data" => member} = json_response(conn, 200)
      assert member["subscriptionPausedUntil"] == nil
      assert member["membershipStatus"] == "active"
    end

    test "rejects out-of-range pause dates", %{conn: conn} do
      member_id = "11111111-1111-1111-1111-111111111111"
      insert_member(auth_user_id: member_id, customer_id: "cus_invalid")

      too_soon = DateTime.utc_now() |> DateTime.add(12, :hour) |> DateTime.to_iso8601()

      conn =
        conn
        |> put_req_header("authorization", "Bearer self-token")
        |> post("/api/members/#{member_id}/membership/pause", %{"pauseUntil" => too_soon})

      assert %{"errors" => %{"detail" => "Invalid membership pause payload"}} =
               json_response(conn, 422)
    end

    test "returns 403 when a non-admin pauses another member", %{conn: conn} do
      %{auth_user_id: member_id} = insert_member([])
      pause_until = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.to_iso8601()

      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> post("/api/members/#{member_id}/membership/pause", %{"pauseUntil" => pause_until})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  describe "options" do
    test "returns public enum option labels", %{conn: conn} do
      conn = get(conn, "/api/options")

      assert %{"data" => %{"genders" => genders, "weapons" => weapons}} = json_response(conn, 200)
      assert "man (cis)" in genders
      assert "longsword" in weapons
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

  defp expect_subscription_list(bypass, customer_id, subscriptions) do
    Bypass.expect(bypass, "GET", "/v1/subscriptions", fn conn ->
      assert conn.query_params["customer"] == customer_id
      assert conn.query_params["limit"] == "10"

      stripe_json(conn, %{
        "object" => "list",
        "data" => subscriptions,
        "has_more" => false
      })
    end)
  end

  defp active_membership_subscription do
    %{
      "id" => "sub_membership",
      "status" => "active",
      "pause_collection" => nil,
      "items" => %{
        "data" => [
          %{"price" => %{"lookup_key" => "standard_membership_fee"}}
        ]
      }
    }
  end

  defp paused_membership_subscription do
    active_membership_subscription()
    |> Map.put("pause_collection", %{"behavior" => "void", "resumes_at" => 1_800_000_000})
  end

  defp stripe_json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp insert_member(attrs \\ []) do
    today = Date.utc_today()
    date_of_birth = %{today | year: today.year - Keyword.get(attrs, :age, 20)}

    Dhc.MemberFixtures.member_fixture(
      gender: Keyword.get(attrs, :gender, "man (cis)"),
      date_of_birth: date_of_birth,
      preferred_weapon: Keyword.get(attrs, :preferred_weapon, ["longsword"]),
      is_active: Keyword.get(attrs, :is_active, true),
      first_name: Keyword.get(attrs, :first_name, "Test"),
      last_name: Keyword.get(attrs, :last_name, "Member"),
      subscription_paused_until: Keyword.get(attrs, :subscription_paused_until),
      auth_user_id: Keyword.get(attrs, :auth_user_id),
      email: Keyword.get(attrs, :email),
      phone_number: Keyword.get(attrs, :phone_number),
      customer_id: Keyword.get(attrs, :customer_id)
    )
  end
end
