defmodule Dhc.Discord.RosterCaptureTest do
  use Dhc.DataCase, async: false

  import Bitwise
  import Dhc.AuthFixtures

  alias Dhc.Auth.UserRole

  alias Dhc.Discord.{
    RosterCapture,
    RosterExecution,
    RosterPackage,
    RosterReceipt
  }

  defmodule Sleeper do
    def sleep(milliseconds), do: send(self(), {:slept, milliseconds}) && :ok
  end

  defmodule ApprovedExecutionStore do
    def claim(execution_id, options) do
      {:ok, %{id: execution_id, actor_id: options.test_actor_id}}
    end

    def complete(_execution, outcome) do
      send(self(), {:execution_completed, outcome})
      {:ok, %{status: outcome}}
    end
  end

  defmodule MismatchClient do
    def application(_token, _options),
      do: {:ok, %{status: 200, headers: [], body: %{"id" => "observed-app"}}}

    def members(_token, _guild, _cursor, _limit, _options),
      do: raise("members endpoint must not be called after an identity mismatch")
  end

  defmodule FailingReceiptStore do
    def create(_attrs), do: {:error, :receipt_database_unavailable}
    def capture_exists?(_capture_id), do: false
  end

  defmodule CapturedClient do
    def application(_token, _options),
      do: {:ok, %{status: 200, headers: [], body: %{"id" => "app-1"}}}

    def members(_token, _guild, nil, 1, _options),
      do:
        {:ok,
         %{
           status: 200,
           headers: [],
           body: [
             %{
               "nick" => "Nick",
               "user" => %{"id" => "1", "username" => "one", "global_name" => "One"}
             }
           ]
         }}

    def members(_token, _guild, nil, 1_000, _options),
      do:
        {:ok,
         %{
           status: 200,
           headers: [],
           body: [%{"user" => %{"id" => "1", "username" => "one"}}]
         }}

    def members(_token, _guild, "1", 1_000, _options),
      do: {:ok, %{status: 200, headers: [], body: []}}
  end

  defmodule CaptureInsertFails do
    def create(%{kind: :preflight} = attrs),
      do: {:ok, Map.put(attrs, :id, Ecto.UUID.generate())}

    def create(%{kind: :capture}), do: {:error, :capture_receipt_rejected}
    def capture_exists?(_capture_id), do: false
  end

  defmodule CaptureInsertFailsAndLocksDirectory do
    def create(%{kind: :preflight} = attrs),
      do: {:ok, Map.put(attrs, :id, Ecto.UUID.generate())}

    def create(%{kind: :capture}) do
      :ok = File.chmod(Process.get(:roster_package_dir), 0o500)
      {:error, :capture_receipt_rejected}
    end

    def capture_exists?(_capture_id), do: false
  end

  setup do
    package_dir =
      Path.join(System.tmp_dir!(), "discord-roster-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.chmod(package_dir, 0o700)
      File.rm_rf(package_dir)
    end)

    %{package_dir: package_dir}
  end

  test "persists matching package, filename, receipt, and result IDs with privacy-safe data", %{
    package_dir: package_dir
  } do
    stub = captured_stub()
    execution = execution_fixture()
    options = options(package_dir, execution, stub)

    assert {:ok, result} = RosterCapture.capture(options)
    assert result.count == 2
    assert result.reconciliation == "captured 2 roster entries; staged assignments created: 0"
    assert Path.basename(result.package_path) == "#{result.capture_id}.discord-roster.enc"

    capture = Repo.get!(RosterReceipt, result.capture_id)
    preflight = Repo.get!(RosterReceipt, result.preflight_receipt_id)
    execution = Repo.get!(RosterExecution, execution.id)

    assert capture.id == result.capture_id
    assert capture.preflight_receipt_id == preflight.id
    assert capture.execution_id == execution.id
    assert capture.actor_id == execution.actor_id
    assert capture.package_digest == result.digest
    assert capture.record_count == 2
    assert preflight.record_count == 1
    assert preflight.bot_application_id == "app-1"
    assert preflight.observed_bot_application_id == "app-1"
    assert execution.status == :succeeded

    assert {:ok, package} = RosterPackage.read(result.package_path, options.package_key)
    assert package["capture_id"] == result.capture_id
    assert package["guild_id"] == "guild-1"
    assert package["tool_revision"] == "test-revision"
    assert package["record_count"] == 2
    assert package["digest"] == result.digest

    assert package["users"] == [
             %{
               "id" => "1",
               "username" => "one",
               "global_name" => "One",
               "nickname" => "Nick"
             },
             %{
               "id" => "2",
               "username" => "two",
               "global_name" => nil,
               "nickname" => nil
             }
           ]

    encrypted = File.read!(result.package_path)
    refute encrypted =~ "one"
    refute encrypted =~ "test-bot-token"

    refute inspect(preflight) =~ "one"
    refute inspect(capture) =~ "one"
    refute inspect(capture) =~ "test-bot-token"

    assert mode(package_dir) == 0o700
    assert mode(result.package_path) == 0o600

    assert_receive {:discord_request, "/api/v10/guilds/guild-1/members", %{"limit" => "1"}}
    assert_receive {:discord_request, "/api/v10/guilds/guild-1/members", %{"limit" => "1000"}}

    assert :ok = RosterCapture.cleanup(result.package_path)
    refute File.exists?(result.package_path)
  end

  test "repeated capture requires a new approval and creates a distinct receipt only", %{
    package_dir: package_dir
  } do
    first = execution_fixture()
    first_options = options(package_dir, first, captured_stub())

    assert {:ok, first_result} = RosterCapture.capture(first_options)
    assert {:error, :execution_not_approved} = RosterCapture.capture(first_options)

    second = execution_fixture()

    assert {:ok, second_result} =
             RosterCapture.capture(options(package_dir, second, captured_stub()))

    refute first_result.capture_id == second_result.capture_id
    assert Repo.aggregate(from(r in RosterReceipt, where: r.kind == :capture), :count) == 2
  end

  test "rejects an approved execution whose actor lacks a current administration role", %{
    package_dir: package_dir
  } do
    execution = execution_fixture("member")

    assert {:error, :execution_actor_not_authorized} =
             RosterCapture.capture(options(package_dir, execution, captured_stub()))

    assert Repo.get!(RosterExecution, execution.id).status == :approved
    refute File.exists?(package_dir)
  end

  test "preflight rejects every malformed approved recognition field and records failure", %{
    package_dir: package_dir
  } do
    malformed_members = [
      put_in(preflight_member(), [Access.at(0), "user", "id"], 1),
      put_in(preflight_member(), [Access.at(0), "user", "username"], nil),
      put_in(preflight_member(), [Access.at(0), "user", "global_name"], %{"bad" => true}),
      put_in(preflight_member(), [Access.at(0), "nick"], ["bad"])
    ]

    Enum.each(malformed_members, fn malformed ->
      execution = execution_fixture()
      stub = captured_stub(%{preflight: {:json, 200, malformed, []}})

      assert {:error, :malformed_roster_user} =
               RosterCapture.capture(options(package_dir, execution, stub))

      receipt =
        Repo.one!(
          from receipt in RosterReceipt,
            where: receipt.execution_id == ^execution.id and receipt.kind == :preflight
        )

      assert receipt.status == :failed
      assert receipt.result == "preflight verification failed"
      assert Repo.get!(RosterExecution, execution.id).status == :failed
      refute File.exists?(package_dir)
    end)
  end

  test "identity mismatch records expected and observed evidence and a bound digest", %{
    package_dir: package_dir
  } do
    execution = execution_fixture()
    stub = captured_stub(%{application: {:json, 200, %{"id" => "other-app"}, []}})

    assert {:error, :unexpected_bot_application} =
             RosterCapture.capture(options(package_dir, execution, stub))

    receipt =
      Repo.one!(
        from r in RosterReceipt, where: r.execution_id == ^execution.id and r.kind == :preflight
      )

    assert receipt.status == :failed
    assert receipt.bot_application_id == "app-1"
    assert receipt.observed_bot_application_id == "other-app"

    assert receipt.evidence_digest ==
             digest(%{
               expected_application_id: "app-1",
               guild_id: "guild-1",
               application_endpoint: "oauth2_applications_me",
               members_endpoint: "guild_members",
               application_status: 200,
               observed_application_id: "other-app",
               result: "identity_mismatch"
             })
  end

  test "surfaces failed-preflight receipt persistence instead of losing audit evidence", %{
    package_dir: package_dir
  } do
    options = isolated_options(package_dir, MismatchClient, FailingReceiptStore)

    assert {:error,
            {:preflight_receipt_persistence_failed, :unexpected_bot_application,
             :receipt_database_unavailable}} = RosterCapture.capture(options)

    assert_receive {:execution_completed, :failed}
  end

  test "real Req boundary exposes every fractional 429 and rate-limit wait", %{
    package_dir: package_dir
  } do
    counter = start_supervised!({Agent, fn -> 0 end})

    page_one = members_page_one()

    stub =
      captured_stub(%{
        page_1: fn conn ->
          case Agent.get_and_update(counter, fn count -> {count, count + 1} end) do
            0 ->
              json_response(conn, 429, %{"retry_after" => 0.0011})

            1 ->
              json_response(conn, 429, %{"retry_after" => 0.0021})

            _ ->
              json_response(conn, 200, page_one, [
                {"x-ratelimit-remaining", "0"},
                {"x-ratelimit-reset-after", "0.0011"}
              ])
          end
        end
      })

    assert {:ok, %{count: 2}} =
             RosterCapture.capture(options(package_dir, execution_fixture(), stub))

    assert_receive {:slept, 2}
    assert_receive {:slept, 3}
    assert_receive {:slept, 2}
    assert Agent.get(counter, & &1) == 3
  end

  test "fails closed when exhausted rate-limit headers omit reset metadata", %{
    package_dir: package_dir
  } do
    stub =
      captured_stub(%{
        page_1: {:json, 200, members_page_one(), [{"x-ratelimit-remaining", "0"}]}
      })

    assert {:error, :malformed_rate_limit_headers} =
             RosterCapture.capture(options(package_dir, execution_fixture(), stub))

    refute File.exists?(package_dir)
  end

  test "fails closed on duplicate users, cursor non-progress, and incomplete transport", %{
    package_dir: package_dir
  } do
    duplicate = [
      %{"user" => %{"id" => "1", "username" => "one"}},
      %{"user" => %{"id" => "1", "username" => "again"}}
    ]

    cases = [
      {%{page_1: {:json, 200, duplicate, []}}, :duplicate_roster_user},
      {%{page_2: {:json, 200, members_page_one(), []}}, :cursor_non_progress},
      {%{page_2: :transport_error}, :guild_members_transport_failure}
    ]

    Enum.each(cases, fn {overrides, reason} ->
      execution = execution_fixture()

      assert {:error, ^reason} =
               RosterCapture.capture(options(package_dir, execution, captured_stub(overrides)))

      refute File.exists?(package_dir)
    end)
  end

  test "deletes a package when capture receipt insertion fails", %{package_dir: package_dir} do
    options = isolated_options(package_dir, CapturedClient, CaptureInsertFails)

    assert {:error, :capture_receipt_rejected} = RosterCapture.capture(options)
    assert {:ok, []} = File.ls(package_dir)
    assert_receive {:execution_completed, :failed}
  end

  test "surfaces package cleanup failure when receipt insertion and deletion both fail", %{
    package_dir: package_dir
  } do
    Process.put(:roster_package_dir, package_dir)
    options = isolated_options(package_dir, CapturedClient, CaptureInsertFailsAndLocksDirectory)

    assert {:error, {:package_cleanup_failed, :capture_receipt_rejected, :eacces}} =
             RosterCapture.capture(options)

    assert_receive {:execution_completed, :failed}
  end

  test "reconciles interrupted temporary files and final packages without receipts", %{
    package_dir: package_dir
  } do
    orphan_id = Ecto.UUID.generate()
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    assert {:ok, orphan_path} = RosterPackage.write(package_dir, orphan_id, %{orphan: true}, key)

    temporary_path = Path.join(package_dir, ".interrupted.discord-roster.tmp")
    File.write!(temporary_path, "encrypted-fragment")

    assert {:ok, result} =
             RosterCapture.capture(options(package_dir, execution_fixture(), captured_stub()))

    refute File.exists?(orphan_path)
    refute File.exists?(temporary_path)
    assert File.exists?(result.package_path)
  end

  test "rejects a broadly accessible package directory", %{package_dir: package_dir} do
    File.mkdir_p!(package_dir)
    File.chmod!(package_dir, 0o755)

    assert {:error, {:unsafe_package_permissions, :directory, 0o755}} =
             RosterCapture.capture(options(package_dir, execution_fixture(), captured_stub()))
  end

  test "does not delete an existing package when a capture ID collides", %{
    package_dir: package_dir
  } do
    capture_id = Ecto.UUID.generate()
    key = Base.encode64(:crypto.strong_rand_bytes(32))

    assert {:ok, package_path} =
             RosterPackage.write(package_dir, capture_id, %{capture: "original"}, key)

    original_encrypted = File.read!(package_path)

    assert {:error, :review_package_already_exists} =
             RosterPackage.write(package_dir, capture_id, %{capture: "replacement"}, key)

    assert File.read!(package_path) == original_encrypted
    assert {:ok, %{"capture" => "original"}} = RosterPackage.read(package_path, key)
  end

  test "task configuration requires an explicit immutable revision and approved execution ID" do
    env = %{
      "DISCORD_ROSTER_BOT_TOKEN" => "token",
      "DISCORD_ROSTER_GUILD_ID" => "guild",
      "DISCORD_ROSTER_BOT_APPLICATION_ID" => "app",
      "DISCORD_ROSTER_EXECUTION_ID" => Ecto.UUID.generate(),
      "DISCORD_ROSTER_PACKAGE_DIR" => "/restricted",
      "DISCORD_ROSTER_PACKAGE_KEY" => Base.encode64(:crypto.strong_rand_bytes(32))
    }

    getter = &Map.get(env, &1)

    assert_raise Mix.Error, ~r/DISCORD_ROSTER_TOOL_REVISION is required/, fn ->
      Mix.Tasks.Dhc.Discord.RosterCapture.load_options!(getter)
    end

    options =
      env
      |> Map.put("DISCORD_ROSTER_TOOL_REVISION", "immutable-sha")
      |> then(fn complete_env ->
        Mix.Tasks.Dhc.Discord.RosterCapture.load_options!(&Map.get(complete_env, &1))
      end)

    assert options.execution_id == env["DISCORD_ROSTER_EXECUTION_ID"]
    assert options.tool_revision == "immutable-sha"
    refute Map.has_key?(options, :actor_id)

    assert_raise Mix.Error, ~r/must be approved-one-shot/, fn ->
      Mix.Tasks.Dhc.Discord.RosterCapture.validate_execution_profile!(fn _name -> nil end)
    end

    assert :ok =
             Mix.Tasks.Dhc.Discord.RosterCapture.validate_execution_profile!(fn _name ->
               "approved-one-shot"
             end)
  end

  defp execution_fixture(role \\ "admin") do
    principal = principal_fixture()
    Repo.insert!(%UserRole{principal_id: principal.id, role: role})

    %RosterExecution{actor_id: principal.id}
    |> RosterExecution.approval_changeset(%{
      guild_id: "guild-1",
      bot_application_id: "app-1",
      tool_revision: "test-revision",
      status: :approved,
      approved_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    })
    |> Repo.insert!()
  end

  defp options(package_dir, execution, stub) do
    %{
      token: "test-bot-token",
      guild_id: "guild-1",
      bot_application_id: "app-1",
      execution_id: execution.id,
      tool_revision: "test-revision",
      package_dir: package_dir,
      package_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      request_options: [plug: {Req.Test, stub}],
      sleeper: Sleeper
    }
  end

  defp isolated_options(package_dir, client, receipt_store) do
    %{
      token: "test-bot-token",
      guild_id: "guild-1",
      bot_application_id: "app-1",
      execution_id: Ecto.UUID.generate(),
      tool_revision: "test-revision",
      package_dir: package_dir,
      package_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      test_actor_id: Ecto.UUID.generate(),
      client: client,
      receipt_store: receipt_store,
      execution_store: ApprovedExecutionStore,
      sleeper: Sleeper
    }
  end

  defp captured_stub(overrides \\ %{}) do
    stub = {__MODULE__, System.unique_integer([:positive])}
    test_pid = self()

    Req.Test.stub(stub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:discord_request, conn.request_path, conn.query_params})
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot test-bot-token"]

      key = request_key(conn)
      response = Map.get(overrides, key, default_response(key))
      render_response(response, conn)
    end)

    stub
  end

  defp request_key(%{request_path: "/api/v10/oauth2/applications/@me"}), do: :application

  defp request_key(%{query_params: %{"limit" => "1"}}), do: :preflight

  defp request_key(%{query_params: %{"limit" => "1000", "after" => "1"}}),
    do: :page_2

  defp request_key(%{query_params: %{"limit" => "1000", "after" => "2"}}),
    do: :empty

  defp request_key(%{query_params: %{"limit" => "1000"}}), do: :page_1

  defp default_response(:application), do: {:json, 200, fixture!("application.json"), []}
  defp default_response(:preflight), do: {:json, 200, preflight_member(), []}
  defp default_response(:page_1), do: {:json, 200, members_page_one(), []}
  defp default_response(:page_2), do: {:json, 200, fixture!("members-page-2.json"), []}
  defp default_response(:empty), do: {:json, 200, fixture!("members-empty.json"), []}

  defp render_response(response, conn) when is_function(response, 1), do: response.(conn)

  defp render_response({:json, status, body, headers}, conn),
    do: json_response(conn, status, body, headers)

  defp render_response(:transport_error, conn), do: Req.Test.transport_error(conn, :closed)

  defp json_response(conn, status, body, headers \\ []) do
    conn =
      Enum.reduce(headers, Plug.Conn.put_status(conn, status), fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)

    Req.Test.json(conn, body)
  end

  defp preflight_member, do: fixture!("preflight-member.json")
  defp members_page_one, do: fixture!("members-page-1.json")

  defp fixture!(name) do
    __DIR__
    |> Path.join("../../fixtures/discord/#{name}")
    |> File.read!()
    |> Jason.decode!()
  end

  defp mode(path), do: File.lstat!(path).mode &&& 0o777

  defp digest(term),
    do: :crypto.hash(:sha256, Jason.encode!(term)) |> Base.encode16(case: :lower)
end
