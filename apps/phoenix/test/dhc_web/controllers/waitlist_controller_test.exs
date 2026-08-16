defmodule DhcWeb.WaitlistControllerTest do
  use DhcWeb.ConnCase, async: false

  import Ecto.Query

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

    test "allows all waitlist admin roles", %{conn: _conn} do
      for role <- ~w(admin president committee_coordinator beginners_coordinator coach) do
        set_waitlist_open(false)

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> patch("/api/waitlist/status", %{"isOpen" => true})

        assert %{"data" => %{"isOpen" => true}} = json_response(conn, 200)
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
    test "updates waitlist status and last status change", %{conn: conn} do
      id = insert_waitlist_profile(status: "waiting")
      before_update = Repo.get!(WaitlistEntry, id).last_status_change

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/waitlist/entries/#{id}", %{status: "deferred"})

      assert %{"data" => %{"id" => ^id, "status" => "deferred", "lastStatusChange" => changed_at}} =
               json_response(conn, 200)

      assert DateTime.compare(DateTime.from_iso8601(changed_at) |> elem(1), before_update) in [
               :gt,
               :eq
             ]
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

    test "returns 422 for invalid status", %{conn: conn} do
      id = insert_waitlist_profile()

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> patch("/api/waitlist/entries/#{id}", %{status: "declined"})

      assert %{"errors" => %{"detail" => "Invalid waitlist status"}} = json_response(conn, 422)
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

      assert %{"data" => %{"id" => id, "status" => "waiting"}} = json_response(conn, 201)

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

      assert %{"data" => %{"id" => id, "status" => "waiting"}} = json_response(conn, 201)
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

    test "returns 409 for duplicate email", %{conn: conn} do
      set_waitlist_open(true)
      payload = adult_payload(email: "duplicate@example.com")

      assert %{"data" => %{"status" => "waiting"}} =
               conn |> post("/api/waitlist/entries", payload) |> json_response(201)

      conn = post(build_conn(), "/api/waitlist/entries", payload)

      assert %{"errors" => %{"detail" => "This email is already on the waitlist"}} =
               json_response(conn, 409)
    end

    test "enforces waitlist closed server-side", %{conn: conn} do
      set_waitlist_open(false)

      conn = post(conn, "/api/waitlist/entries", adult_payload())

      assert %{"errors" => %{"detail" => "Waitlist is closed"}} = json_response(conn, 403)
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

      assert %{"errors" => %{"detail" => "email has invalid format"}} =
               json_response(conn, 422)

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
