defmodule Dhc.Discord.RosterCaptureTest do
  use ExUnit.Case, async: true

  alias Dhc.Discord.RosterCapture

  defmodule FakeClient do
    def application(_token), do: {:ok, %{status: 200, body: %{"id" => "app-1"}, headers: []}}
    def members(_token, _guild, cursor), do: send(self(), {:members, cursor}) && response(cursor)

    defp response(nil),
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

    defp response("1"),
      do:
        {:ok,
         %{
           status: 200,
           headers: [],
           body: [%{"user" => %{"id" => "2", "username" => "two", "global_name" => nil}}]
         }}

    defp response("2"), do: {:ok, %{status: 200, headers: [], body: []}}
  end

  defmodule RateLimitedClient do
    def application(token), do: FakeClient.application(token)
    def members(token, guild, nil), do: FakeClient.members(token, guild, nil)

    def members(token, guild, "1") do
      if Agent.get_and_update(:rate_limit_counter, fn count -> {count > 0, count + 1} end) do
        FakeClient.members(token, guild, "1")
      else
        {:ok, %{status: 429, headers: [], body: %{"retry_after" => 0}}}
      end
    end

    def members(token, guild, "2"), do: FakeClient.members(token, guild, "2")
  end

  defmodule DuplicateClient do
    def application(token), do: FakeClient.application(token)

    def members(_token, _guild, _after),
      do:
        {:ok,
         %{
           status: 200,
           headers: [],
           body: [
             %{"user" => %{"id" => "1", "username" => "one"}},
             %{"user" => %{"id" => "1", "username" => "again"}}
           ]
         }}
  end

  defmodule ReceiptStore do
    def create(attrs) do
      send(self(), {:receipt, attrs})
      {:ok, Map.put(attrs, :id, Map.get(attrs, :id, Ecto.UUID.generate()))}
    end
  end

  defmodule Sleeper do
    def sleep(milliseconds), do: send(self(), {:slept, milliseconds}) && :ok
  end

  test "captures complete opaque pagination into an encrypted package and retains only safe receipts" do
    package_dir =
      Path.join(System.tmp_dir!(), "discord-roster-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(package_dir) end)

    assert {:ok, result} = RosterCapture.capture(options(package_dir, FakeClient))
    assert result.count == 2
    assert result.reconciliation == "captured 2 roster entries; staged assignments created: 0"
    assert File.exists?(result.package_path)
    assert File.read!(result.package_path) != "one"
    assert_receive {:members, nil}
    assert_receive {:members, "1"}
    assert_receive {:members, "2"}
    assert_receive {:receipt, preflight}
    assert_receive {:receipt, capture}
    refute inspect(preflight) =~ "one"
    refute inspect(capture) =~ "one"
    refute inspect(capture) =~ "test-bot-token"
    assert capture.record_count == 2
    assert capture.package_digest == result.digest
    assert :ok = RosterCapture.cleanup(result.package_path)
    refute File.exists?(result.package_path)
  end

  test "obeys Discord 429 retry_after before continuing pagination" do
    package_dir =
      Path.join(System.tmp_dir!(), "discord-roster-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(package_dir) end)

    start_supervised!(%{
      id: :rate_limit_counter,
      start: {Agent, :start_link, [fn -> 0 end, [name: :rate_limit_counter]]}
    })

    assert {:ok, %{count: 2}} = RosterCapture.capture(options(package_dir, RateLimitedClient))
    assert_receive {:slept, 0}
  end

  test "fails closed when a page repeats a Discord user" do
    package_dir =
      Path.join(System.tmp_dir!(), "discord-roster-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(package_dir) end)

    assert {:error, :duplicate_roster_user} =
             RosterCapture.capture(options(package_dir, DuplicateClient))

    refute File.exists?(package_dir)
  end

  defp options(package_dir, client) do
    %{
      token: "test-bot-token",
      guild_id: "guild-1",
      bot_application_id: "app-1",
      actor_id: Ecto.UUID.generate(),
      tool_revision: "test-revision",
      package_dir: package_dir,
      package_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      client: client,
      receipt_store: ReceiptStore,
      sleeper: Sleeper
    }
  end
end
