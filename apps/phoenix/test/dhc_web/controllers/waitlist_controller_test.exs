defmodule DhcWeb.WaitlistControllerTest do
  use DhcWeb.ConnCase, async: false

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  alias DhcWeb.OpenApiVerifier

  # `coach` gets a token so the tests can show it no longer holds
  # `beginners.waitlist.manage` (spec story 23).
  @waitlist_admin_roles ~w(admin president committee_coordinator beginners_coordinator coach)
  @waitlist_managers ~w(admin president committee_coordinator beginners_coordinator)

  setup do
    original =
      OpenApiVerifier.install(
        generate_sub: true,
        roles: @waitlist_admin_roles,
        role_email: "admin@example.com",
        tokens: %{
          "member-token" => %{email: "member@example.com", roles: ["member"]}
        }
      )

    on_exit(fn -> OpenApiVerifier.restore(original) end)
  end

  describe "contract" do
    setup do
      {:ok, spec} =
        :dhc |> Application.app_dir("priv/api/openapi.yaml") |> YamlElixir.read_from_file()

      %{schemas: spec["components"]["schemas"], spec: spec}
    end

    test "WaitlistStatus is the five standings", %{schemas: schemas} do
      assert schemas["WaitlistStatus"]["enum"] == Dhc.Waitlist.Standing.statuses()
    end

    test "the update request admits admin notes only", %{schemas: schemas} do
      request = schemas["WaitlistEntryUpdateRequest"]

      assert Map.keys(request["properties"]) == ["adminNotes"]
      assert request["additionalProperties"] == false
    end

    test "the entries filter lists waiting or removed people", %{spec: spec} do
      [status] =
        for %{"name" => "status"} = param <-
              spec["paths"]["/waitlist/entries"]["get"]["parameters"],
            do: param

      assert status["schema"]["enum"] == ~w(waiting removed)
      assert status["schema"]["default"] == "waiting"
    end

    test "the restore operation answers the entry or a coded 409", %{spec: spec} do
      operation = spec["paths"]["/waitlist/entries/{id}/restore"]["post"]

      assert operation["operationId"] == "waitlist.restoreEntry"
      assert Map.keys(operation["responses"]) |> Enum.sort() == ~w(200 401 403 404 409)

      assert operation["responses"]["200"]["content"]["application/json"]["schema"] ==
               %{"$ref" => "#/components/schemas/WaitlistEntryResponse"}
    end

    test "registration holds the first name to its Intake Email placeholder maximum", %{
      schemas: schemas
    } do
      max = schemas["WaitlistEntryCreateRequest"]["properties"]["firstName"]["maxLength"]

      assert max == Dhc.Waitlist.first_name_max_length()
      assert max == Dhc.BeginnersWorkshops.IntakeEmails.EmailType.maxima()["firstName"]
    end

    test "an entry renders exactly the WaitlistEntry properties", %{
      conn: conn,
      schemas: schemas
    } do
      id = insert_waitlist_profile(status: "removed")

      entry =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries/#{id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.sort(Map.keys(entry)) ==
               Enum.sort(Map.keys(schemas["WaitlistEntry"]["properties"]))

      assert %{"status" => "removed", "removedAt" => removed_at} = entry
      assert is_binary(removed_at)
    end
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

  describe "PATCH /api/waitlist/status" do
    test "sets and returns the waitlist status", %{conn: conn} do
      set_waitlist_open(false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/waitlist/status", %{"isOpen" => true})

      assert %{"data" => %{"isOpen" => true}} = json_response(conn, 200)
      assert Dhc.Waitlist.open?()
    end

    test "allows officers to toggle the waitlist", %{conn: _conn} do
      for role <- ~w(admin president committee_coordinator) do
        set_waitlist_open(false)

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> patch("/api/waitlist/status", %{"isOpen" => true})

        assert %{"data" => %{"isOpen" => true}} = json_response(conn, 200)
      end
    end

    test "rejects beginners staff who are not officers (403)", %{conn: _conn} do
      for role <- ~w(beginners_coordinator coach) do
        set_waitlist_open(false)

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> patch("/api/waitlist/status", %{"isOpen" => true})

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403),
               "#{role} must not toggle the waitlist"

        refute Dhc.Waitlist.open?()
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = patch(conn, "/api/waitlist/status", %{"isOpen" => true})

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks a waitlist admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> patch("/api/waitlist/status", %{"isOpen" => true})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 422 when isOpen is missing or not boolean", %{conn: _conn} do
      for payload <- [%{}, %{"isOpen" => "true"}] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer admin-token")
          |> patch("/api/waitlist/status", payload)

        assert %{"errors" => %{"detail" => "isOpen must be a boolean"}} =
                 json_response(conn, 422)
      end
    end
  end

  describe "analytics" do
    test "returns analytics over waiting people only", %{conn: conn} do
      insert_waitlist_profile(status: "waiting", gender: "man (cis)", age: 20)
      insert_waitlist_profile(status: "waiting", gender: "woman (cis)", age: 30)
      insert_waitlist_profile(status: "waiting", gender: "man (cis)", age: 20)
      insert_waitlist_profile(status: "removed", gender: "other", age: 40)
      insert_waitlist_profile(status: "attended", gender: "other", age: 50)
      insert_waitlist_profile(status: "invited", gender: "other", age: 60)

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

    test "counts every waiting person, even one left out of the age figures",
         %{conn: conn} do
      insert_waitlist_profile(status: "waiting", gender: "man (cis)", age: 20)
      insert_waitlist_profile(status: "waiting", gender: "woman (cis)", age: 30)

      # Their profile is claimed, so it has no say in the age figures.
      Repo.update_all(
        from(p in UserProfile, where: p.gender == "woman (cis)"),
        set: [is_active: true]
      )

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/analytics")

      assert %{"data" => %{"totalCount" => 2, "averageAge" => average_age}} =
               json_response(conn, 200)

      assert_in_delta average_age, 20.0, 0.01
      # The report's queue reads the same Waiting count.
      assert [_, _] = Dhc.Waitlist.queue_report(DateTime.utc_now()).waiting_since
    end

    test "allows every Waitlist manager and refuses coaches", %{conn: _conn} do
      for role <- @waitlist_managers do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/waitlist/analytics")

        assert %{"data" => %{"totalCount" => 0}} = json_response(conn, 200)
      end

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer coach-token")
        |> get("/api/waitlist/analytics")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
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
    test "allows every Waitlist manager and refuses coaches", %{conn: _conn} do
      for role <- @waitlist_managers do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/waitlist/entries")

        assert %{"data" => %{"entries" => [], "totalCount" => 0}} = json_response(conn, 200)
      end

      for path <- ["/api/waitlist/entries", "/api/waitlist/entries/#{insert_waitlist_profile()}"] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer coach-token")
          |> get(path)

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
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

    test "returns camelCase entries and lists only waiting people by default", %{conn: conn} do
      insert_waitlist_profile(
        status: "waiting",
        first_name: "Ada",
        last_name: "Lovelace",
        age: 20
      )

      for status <- ~w(removed attended invited joined) do
        insert_waitlist_profile(status: status, first_name: "Grace", last_name: status, age: 30)
      end

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
      assert entry["status"] == "waiting"
      assert entry["removedAt"] == nil
      refute Map.has_key?(entry, "searchText")
    end

    test "lists removed people behind the removed filter", %{conn: conn} do
      insert_waitlist_profile(status: "waiting", first_name: "Ada", last_name: "Lovelace")
      insert_waitlist_profile(status: "removed", first_name: "Grace", last_name: "Hopper")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries", status: "removed")

      assert %{
               "data" => %{
                 "entries" => [%{"status" => "removed", "removedAt" => removed_at}],
                 "totalCount" => 1
               }
             } = json_response(conn, 200)

      assert {:ok, _at, 0} = DateTime.from_iso8601(removed_at)
    end

    test "returns 400 for a status outside the Waitlist view", %{conn: _conn} do
      for status <- ~w(attended invited joined paid) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer admin-token")
          |> get("/api/waitlist/entries", status: status)

        assert %{"errors" => %{"detail" => "Invalid waitlist entries query"}} =
                 json_response(conn, 400)
      end
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

  describe "show" do
    test "returns one waitlist entry by id", %{conn: conn} do
      id = insert_waitlist_profile(first_name: "Ada", last_name: "Lovelace")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries/#{id}")

      assert %{"data" => %{"id" => ^id, "fullName" => "Ada Lovelace"}} =
               json_response(conn, 200)
    end

    test "numbers a waiting entry within the queue, like the default listing", %{conn: conn} do
      insert_waitlist_profile(status: "removed", seconds: 0)
      id = insert_waitlist_profile(status: "waiting", seconds: 1)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries/#{id}")

      assert %{"data" => %{"id" => ^id, "position" => 1}} = json_response(conn, 200)
    end

    test "returns 404 for missing waitlist entry", %{conn: conn} do
      missing_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries/#{missing_id}")

      assert %{"errors" => %{"detail" => "Waitlist entry not found"}} = json_response(conn, 404)
    end

    test "preserves waitlist admin authorization", %{conn: conn} do
      id = insert_waitlist_profile()

      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/waitlist/entries/#{id}")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  describe "update" do
    test "refuses to edit Waitlist Status (422) and changes nothing", %{conn: _conn} do
      id = insert_waitlist_profile(status: "waiting")
      before = Repo.get!(WaitlistEntry, id)

      for payload <- [
            %{status: "removed"},
            %{status: "attended", adminNotes: "Sneaky"},
            %{}
          ] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer admin-token")
          |> patch("/api/waitlist/entries/#{id}", payload)

        assert %{
                 "errors" => %{
                   "detail" => "Invalid waitlist entry update payload",
                   "code" => "invalid_payload"
                 }
               } = json_response(conn, 422)
      end

      assert Repo.get!(WaitlistEntry, id) == before
    end

    test "updates admin notes through Phoenix", %{conn: conn} do
      id = insert_waitlist_profile()

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/waitlist/entries/#{id}", %{adminNotes: "Call after grading"})

      assert %{"data" => %{"adminNotes" => "Call after grading"}} = json_response(conn, 200)
      assert Repo.get!(WaitlistEntry, id).admin_notes == "Call after grading"
    end

    test "editing admin notes leaves the standing and its timestamp alone", %{conn: conn} do
      id = insert_waitlist_profile(status: "removed")
      before = Repo.get!(WaitlistEntry, id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/waitlist/entries/#{id}", %{adminNotes: nil})

      assert %{"data" => %{"adminNotes" => nil, "status" => "removed"}} = json_response(conn, 200)

      assert %{status: "removed", removed_at: removed_at, last_status_change: changed} =
               Repo.get!(WaitlistEntry, id)

      assert removed_at == before.removed_at
      assert changed == before.last_status_change
    end
  end

  describe "restore" do
    test "moves a removed entry back to waiting with its original date", %{conn: conn} do
      id = insert_waitlist_profile(status: "removed", seconds: -86_400)
      original = Repo.get!(WaitlistEntry, id)

      entry =
        conn
        |> put_req_header("authorization", "Bearer beginners_coordinator-token")
        |> post("/api/waitlist/entries/#{id}/restore")
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"id" => ^id, "status" => "waiting", "removedAt" => nil} = entry

      restored = Repo.get!(WaitlistEntry, id)
      assert restored.initial_registration_date == original.initial_registration_date
    end

    test "refuses an entry removed more than 3 months ago (409)", %{conn: conn} do
      id = insert_waitlist_profile(status: "removed")

      removed_at =
        DateTime.utc_now() |> DateTime.shift(month: -3, day: -1) |> DateTime.truncate(:second)

      Repo.update_all(from(w in WaitlistEntry, where: w.id == ^id), set: [removed_at: removed_at])

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/waitlist/entries/#{id}/restore")

      assert %{"errors" => %{"code" => "restore_window_passed"}} = json_response(conn, 409)
      assert Repo.get!(WaitlistEntry, id).status == "removed"
    end

    test "refuses an entry that is not removed (409)", %{conn: conn} do
      id = insert_waitlist_profile(status: "waiting")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/waitlist/entries/#{id}/restore")

      assert %{"errors" => %{"code" => "not_removed"}} = json_response(conn, 409)
    end

    test "returns 404 for a missing entry", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/waitlist/entries/#{Ecto.UUID.generate()}/restore")

      assert json_response(conn, 404)
    end

    test "requires beginners.waitlist.manage", %{conn: _conn} do
      id = insert_waitlist_profile(status: "removed")

      for token <- ~w(coach-token member-token) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{token}")
          |> post("/api/waitlist/entries/#{id}/restore")

        assert json_response(conn, 403)
      end

      assert Repo.get!(WaitlistEntry, id).status == "removed"
    end
  end

  describe "guardian" do
    test "returns guardian details for a waitlist entry", %{conn: conn} do
      id = insert_waitlist_profile()

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries/#{id}/guardian")

      assert %{
               "data" => %{
                 "firstName" => "Parent",
                 "lastName" => "Guardian",
                 "phoneNumber" => "+353 1 111 1111"
               }
             } = json_response(conn, 200)
    end

    test "returns null guardian data when entry has no guardian", %{conn: conn} do
      id = insert_waitlist_profile(guardian?: false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/waitlist/entries/#{id}/guardian")

      assert %{"data" => nil} = json_response(conn, 200)
    end
  end

  describe "create" do
    test "creates an adult waitlist entry through the public endpoint", %{conn: conn} do
      set_waitlist_open(true)

      conn = post(conn, "/api/waitlist/entries", adult_payload(email: "Adult@Example.COM"))

      assert json_response(conn, 202) == %{"data" => %{"received" => true}}

      %WaitlistEntry{id: id, status: "waiting"} =
        Repo.get_by!(WaitlistEntry, email: "adult@example.com")

      profile = Repo.get_by!(UserProfile, waitlist_id: id)
      assert profile.is_active == false
      assert profile.first_name == "Ada"
      assert profile.pronouns == "she/her"
      assert Repo.get_by!(WaitlistEntry, id: id).email == "adult@example.com"

      assert Repo.aggregate(
               from(g in Dhc.Waitlist.WaitlistGuardian, where: g.profile_id == ^profile.id),
               :count
             ) == 0
    end

    test "creates an adult entry when pronouns are omitted", %{conn: conn} do
      set_waitlist_open(true)

      payload =
        adult_payload(email: "no-pronouns@example.com")
        |> Map.delete(:pronouns)

      conn = post(conn, "/api/waitlist/entries", payload)

      assert json_response(conn, 202) == %{"data" => %{"received" => true}}

      %WaitlistEntry{id: id} = Repo.get_by!(WaitlistEntry, email: "no-pronouns@example.com")
      profile = Repo.get_by!(UserProfile, waitlist_id: id)
      assert profile.pronouns == ""
    end

    test "creates guardian information for a minor", %{conn: conn} do
      set_waitlist_open(true)

      conn =
        post(
          conn,
          "/api/waitlist/entries",
          adult_payload(
            dateOfBirth: minor_birth_date(),
            guardianFirstName: "Parent",
            guardianLastName: "Guardian",
            guardianPhoneNumber: "+353 1 111 1111"
          )
        )

      assert json_response(conn, 202) == %{"data" => %{"received" => true}}

      %WaitlistEntry{id: id} = Repo.get_by!(WaitlistEntry, email: "ada@example.com")
      profile = Repo.get_by!(UserProfile, waitlist_id: id)

      assert %{first_name: "Parent", last_name: "Guardian", phone_number: "+353 1 111 1111"} =
               Repo.one!(
                 from(g in Dhc.Waitlist.WaitlistGuardian, where: g.profile_id == ^profile.id)
               )
    end

    test "rejects a minor with empty guardian fields with 422", %{conn: conn} do
      set_waitlist_open(true)
      persisted_before = persistence_counts()

      conn =
        post(
          conn,
          "/api/waitlist/entries",
          adult_payload(
            dateOfBirth: minor_birth_date(),
            guardianFirstName: "",
            guardianLastName: "",
            guardianPhoneNumber: ""
          )
        )

      assert %{"errors" => _} = json_response(conn, 422)

      # Nothing was persisted — neither the waitlist entry nor the profile.
      assert persistence_counts() == persisted_before
    end

    test "rejects a minor with guardian fields omitted entirely with 422", %{conn: conn} do
      set_waitlist_open(true)
      persisted_before = persistence_counts()

      conn =
        post(
          conn,
          "/api/waitlist/entries",
          adult_payload(dateOfBirth: minor_birth_date())
        )

      assert %{"errors" => _} = json_response(conn, 422)

      assert persistence_counts() == persisted_before
    end

    test "answers a duplicate email exactly like a new entry and changes nothing", %{
      conn: conn
    } do
      set_waitlist_open(true)
      payload = adult_payload(email: "duplicate@example.com")

      first = post(conn, "/api/waitlist/entries", payload)
      persisted_after_first = persistence_counts()

      second =
        post(
          build_conn(),
          "/api/waitlist/entries",
          %{payload | firstName: "Someone", email: "Duplicate@Example.com"}
        )

      # Same status and byte-identical body: the public endpoint is not an
      # oracle for whether an email is on the waitlist.
      assert first.status == 202
      assert second.status == first.status
      assert second.resp_body == first.resp_body
      assert json_response(second, 202) == %{"data" => %{"received" => true}}

      assert persistence_counts() == persisted_after_first
      assert Repo.get_by!(UserProfile, first_name: "Ada").is_active == false
      refute Repo.get_by(UserProfile, first_name: "Someone")
    end

    test "silently refuses an email on the Waitlist in any standing but removed", %{
      conn: _conn
    } do
      set_waitlist_open(true)

      for standing <- ~w(waiting attended invited joined) do
        id = insert_waitlist_profile(status: standing, first_name: "Kept")
        email = Repo.get!(WaitlistEntry, id).email
        before = Repo.get!(WaitlistEntry, id)
        persisted_before = persistence_counts()

        conn =
          post(
            build_conn(),
            "/api/waitlist/entries",
            adult_payload(email: String.upcase(email), firstName: "Other")
          )

        assert json_response(conn, 202) == %{"data" => %{"received" => true}}
        assert persistence_counts() == persisted_before
        assert Repo.get!(WaitlistEntry, id) == before, "#{standing} entry changed"
        assert Repo.get_by!(UserProfile, waitlist_id: id).first_name == "Kept"
      end
    end

    test "silently refuses an email that belongs to a Principal", %{conn: conn} do
      set_waitlist_open(true)

      {:ok, _} =
        Dhc.Auth.register_principal_with_id(Ecto.UUID.generate(), %{email: "m@example.com"})

      persisted_before = persistence_counts()

      conn = post(conn, "/api/waitlist/entries", adult_payload(email: "M@example.com"))

      assert json_response(conn, 202) == %{"data" => %{"received" => true}}
      assert persistence_counts() == persisted_before
    end

    test "silently refuses an email with a pending Invitation", %{conn: conn} do
      set_waitlist_open(true)

      {:ok, _id} =
        Dhc.Invitations.Repository.insert_pending_invitation(
          %{"email" => "invited@example.com", "dateOfBirth" => "1990-01-01"},
          nil,
          nil
        )

      persisted_before = persistence_counts()

      conn = post(conn, "/api/waitlist/entries", adult_payload(email: "invited@example.com"))

      assert json_response(conn, 202) == %{"data" => %{"received" => true}}
      assert persistence_counts() == persisted_before
    end

    test "a removed email that registers again reopens at the back of the queue", %{
      conn: conn
    } do
      set_waitlist_open(true)
      id = insert_waitlist_profile(status: "removed", seconds: -86_400 * 30, first_name: "Old")
      email = Repo.get!(WaitlistEntry, id).email
      persisted_before = persistence_counts()
      before = DateTime.utc_now() |> DateTime.truncate(:second)

      conn =
        post(
          conn,
          "/api/waitlist/entries",
          adult_payload(email: email, firstName: "New", dateOfBirth: minor_birth_date())
          |> Map.merge(%{
            guardianFirstName: "Fresh",
            guardianLastName: "Guardian",
            guardianPhoneNumber: "+353 1 222 2222"
          })
        )

      assert json_response(conn, 202) == %{"data" => %{"received" => true}}
      assert persistence_counts() == persisted_before

      entry = Repo.get!(WaitlistEntry, id)
      assert entry.status == "waiting"
      assert entry.removed_at == nil
      assert DateTime.compare(entry.initial_registration_date, before) != :lt

      profile = Repo.get_by!(UserProfile, waitlist_id: id)
      assert profile.first_name == "New"

      assert [%{first_name: "Fresh"}] =
               Repo.all(
                 from(g in Dhc.Waitlist.WaitlistGuardian, where: g.profile_id == ^profile.id)
               )
    end

    test "rejects a first name longer than its Intake Email placeholder (40)", %{conn: conn} do
      set_waitlist_open(true)
      persisted_before = persistence_counts()

      conn =
        post(conn, "/api/waitlist/entries", adult_payload(firstName: String.duplicate("a", 41)))

      assert %{"errors" => %{"fields" => %{"firstName" => [message]}}} = json_response(conn, 422)
      assert message =~ "40"
      assert persistence_counts() == persisted_before

      ok =
        post(
          build_conn(),
          "/api/waitlist/entries",
          adult_payload(firstName: String.duplicate("a", 40))
        )

      assert json_response(ok, 202)
    end

    test "enforces waitlist closed server-side", %{conn: conn} do
      set_waitlist_open(false)

      conn = post(conn, "/api/waitlist/entries", adult_payload())

      assert json_response(conn, 403) == %{"errors" => %{"detail" => "Waitlist is closed"}}
    end

    test "rejects an under-16 date of birth with 422", %{conn: conn} do
      set_waitlist_open(true)
      persisted_before = persistence_counts()

      conn =
        post(conn, "/api/waitlist/entries", adult_payload(dateOfBirth: underage_birth_date()))

      assert %{"errors" => %{"detail" => "Invalid waitlist entry payload"}} =
               json_response(conn, 422)

      assert persistence_counts() == persisted_before
    end

    test "rejects missing required fields (firstName, email, dateOfBirth) with 422",
         %{conn: _conn} do
      set_waitlist_open(true)

      for field <- [:firstName, :email, :dateOfBirth] do
        persisted_before = persistence_counts()

        conn =
          build_conn()
          |> post("/api/waitlist/entries", Map.delete(adult_payload(), field))

        assert %{"errors" => %{"detail" => "Invalid waitlist entry payload"}} =
                 json_response(conn, 422)

        assert persistence_counts() == persisted_before
      end
    end

    test "rejects an invalid email format with 422", %{conn: conn} do
      set_waitlist_open(true)
      persisted_before = persistence_counts()

      conn = post(conn, "/api/waitlist/entries", adult_payload(email: "not-an-email"))

      assert json_response(conn, 422) == %{
               "errors" => %{
                 "detail" => "email: has invalid format",
                 "fields" => %{"email" => ["has invalid format"]}
               }
             }

      assert persistence_counts() == persisted_before
    end
  end

  defp set_waitlist_open(open?) do
    value = if open?, do: "true", else: "false"
    result = Repo.query!("UPDATE settings SET value = $1 WHERE key = 'waitlist_open'", [value])
    assert result.num_rows == 1
  end

  defp persistence_counts do
    %{
      user_profiles: Repo.aggregate(UserProfile, :count),
      waitlist_entries: Repo.aggregate(WaitlistEntry, :count)
    }
  end

  defp insert_waitlist_profile(attrs \\ []) do
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
        removed_at: if(Keyword.get(attrs, :status) == "removed", do: registration_date),
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

    if Keyword.get(attrs, :guardian?, true) do
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
    end

    waitlist_id
  end

  defp adult_payload(attrs \\ []) do
    Map.merge(
      %{
        firstName: "Ada",
        lastName: "Lovelace",
        email: "ada@example.com",
        phoneNumber: "+353 1 000 0000",
        dateOfBirth: adult_birth_date(),
        pronouns: "She/Her",
        gender: "woman (cis)",
        medicalConditions: "None",
        socialMediaConsent: "yes_recognizable"
      },
      Map.new(attrs)
    )
  end

  defp adult_birth_date do
    Date.utc_today()
    |> Date.add(-20 * 365)
    |> Date.to_iso8601()
  end

  defp minor_birth_date do
    Date.utc_today()
    |> Date.add(-17 * 365)
    |> Date.to_iso8601()
  end

  defp underage_birth_date do
    Date.utc_today()
    |> Date.add(-15 * 365)
    |> Date.to_iso8601()
  end
end
