defmodule Dhc.Discord.AdapterTest do
  use ExUnit.Case, async: false

  alias Dhc.Discord.Adapter.Test, as: TestAdapter
  alias Dhc.Discord.GuildMember

  setup do
    start_supervised!({TestAdapter, owner: self()})

    original_adapter = Application.get_env(:dhc, :discord_adapter)
    original_guild_id = Application.get_env(:dhc, :discord_guild_id)

    Application.put_env(:dhc, :discord_adapter, TestAdapter)
    Application.put_env(:dhc, :discord_guild_id, "guild-123")

    on_exit(fn ->
      restore_env(:discord_adapter, original_adapter)
      restore_env(:discord_guild_id, original_guild_id)
    end)

    :ok
  end

  test "list guild members uses the configured adapter and returns its outcome" do
    first_page =
      {:ok,
       [
         %GuildMember{
           user_id: "discord-1",
           username: "member.one",
           display_name: "Member One",
           bot: false,
           roles: []
         }
       ]}

    second_page = {:ok, []}
    TestAdapter.script(:list_guild_members, [first_page, second_page])

    assert Dhc.Discord.list_guild_members() == first_page
    assert_receive {:list_guild_members, ["guild-123"]}

    assert Dhc.Discord.list_guild_members() == second_page
  end

  test "add guild member uses the configured adapter and returns scripted outcomes" do
    TestAdapter.script(:add_guild_member, [{:ok, :added}, {:ok, :already_member}])

    assert Dhc.Discord.add_guild_member("discord-1", "oauth-token", "Ada") == {:ok, :added}

    assert_receive {:add_guild_member, ["guild-123", "discord-1", "oauth-token", "Ada"]}

    assert Dhc.Discord.add_guild_member("discord-1", "oauth-token", "Ada") ==
             {:ok, :already_member}
  end

  test "kick guild member uses the configured adapter and returns scripted outcomes" do
    not_found = {:error, %{status: 404}}
    forbidden = {:error, %{status: 403}}
    TestAdapter.script(:kick_guild_member, [:ok, not_found, forbidden])

    assert Dhc.Discord.kick_guild_member("discord-1", "DHC Doctor — Admin: unrecognized") == :ok

    assert_receive {:kick_guild_member,
                    ["guild-123", "discord-1", "DHC Doctor — Admin: unrecognized"]}

    assert Dhc.Discord.kick_guild_member("discord-1", "retry") == not_found
    assert Dhc.Discord.kick_guild_member("discord-1", "protected") == forbidden
  end

  test "the live adapter rejects invalid Discord ids before making a request" do
    Application.put_env(:dhc, :discord_adapter, Dhc.Discord.Adapter.Nostrum)
    Application.put_env(:dhc, :discord_guild_id, "123456789012345678")

    assert {:error, %Dhc.Discord.ApiError{status: 400, message: "invalid Discord user id"}} =
             Dhc.Discord.add_guild_member("not-a-snowflake", "oauth-token", "Ada")
  end

  test "the live adapter rejects line breaks in audit reasons" do
    Application.put_env(:dhc, :discord_adapter, Dhc.Discord.Adapter.Nostrum)
    Application.put_env(:dhc, :discord_guild_id, "123456789012345678")

    assert {:error,
            %Dhc.Discord.ApiError{
              status: 400,
              message: "Discord audit reason cannot contain line breaks"
            }} =
             Dhc.Discord.kick_guild_member(
               "234567890123456789",
               "DHC Doctor — Admin\r\nInjected: value"
             )
  end

  test "the development adapter never mutates a Discord guild" do
    assert {:ok, []} = Dhc.Discord.Adapter.Dev.list_guild_members("guild-123")

    assert {:ok, :added} =
             Dhc.Discord.Adapter.Dev.add_guild_member(
               "guild-123",
               "discord-1",
               "oauth-token",
               "Ada"
             )

    assert :ok =
             Dhc.Discord.Adapter.Dev.kick_guild_member(
               "guild-123",
               "discord-1",
               "development test"
             )
  end

  test "create message returns the message id and forwards params verbatim" do
    TestAdapter.script(:create_message, [{:ok, %{message_id: "111"}}])

    params = %{content: "Hello", allowed_mentions: %{parse: ["everyone"]}, nonce: "nonce-1"}

    assert Dhc.Discord.create_message("222", params) == {:ok, %{message_id: "111"}}
    assert_receive {:create_message, ["222", ^params]}
  end

  test "create thread returns the thread id and forwards params verbatim" do
    TestAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: "333"}}])

    params = %{name: "Roll call", auto_archive_duration: 1440}

    assert Dhc.Discord.create_thread_from_message("222", "111", params) ==
             {:ok, %{thread_id: "333"}}

    assert_receive {:create_thread_from_message, ["222", "111", ^params]}
  end

  test "rate-limit deferral and refused connections classify as their own retryable failures" do
    TestAdapter.script(:create_message, [
      {:error, %Dhc.Discord.ApiError{status: 429, message: "rate limited"}},
      {:error, {:retry_after, 1_000}},
      {:error, {:connection_died, :econnrefused}},
      {:error, :econnrefused}
    ])

    params = %{content: "Hello", allowed_mentions: %{parse: []}}

    assert {:error, {:rate_limited, ": rate limited"}} = Dhc.Discord.create_message("222", params)
    assert {:error, {:rate_limited, _}} = Dhc.Discord.create_message("222", params)
    assert {:error, {:connection_refused, _}} = Dhc.Discord.create_message("222", params)
    assert {:error, {:connection_refused, _}} = Dhc.Discord.create_message("222", params)
  end

  test "deterministic rejections classify by cause with a code-prefixed detail" do
    TestAdapter.script(:create_message, [
      {:error, %Dhc.Discord.ApiError{status: 403, code: 50_013, message: "forbidden"}},
      {:error, %Dhc.Discord.ApiError{status: 404, message: "unknown channel"}},
      {:error, %Dhc.Discord.ApiError{status: 400, message: "payload rejected"}}
    ])

    params = %{content: "Hello", allowed_mentions: %{parse: []}}

    assert {:error, {:permission, "50013: forbidden"}} =
             Dhc.Discord.create_message("222", params)

    assert {:error, {:unknown_channel, ": unknown channel"}} =
             Dhc.Discord.create_message("222", params)

    assert {:error, {:payload_rejected, ": payload rejected"}} =
             Dhc.Discord.create_message("222", params)
  end

  test "timeouts, server errors and unknown failures classify as non-retryable causes" do
    TestAdapter.script(:create_message, [
      {:error, :timeout},
      {:error, %Dhc.Discord.ApiError{status: 408, message: "timeout"}},
      {:error, {:connection_died, :closed}},
      {:error, %Dhc.Discord.ApiError{status: 500, message: "server error"}},
      {:error, %Dhc.Discord.ApiError{status: 503, message: "unavailable"}},
      {:error, :boom},
      {:error, %Dhc.Discord.ApiError{status: 0, message: "mystery"}}
    ])

    params = %{content: "Hello", allowed_mentions: %{parse: []}}

    expected = [
      :timeout,
      :timeout,
      :ambiguous,
      :server_error,
      :server_error,
      :ambiguous,
      :ambiguous
    ]

    for classification <- expected do
      assert {:error, {^classification, detail}} = Dhc.Discord.create_message("222", params)
      assert is_binary(detail)
    end
  end

  test "thread creation follows the same classification" do
    TestAdapter.script(:create_thread_from_message, [
      {:error, %Dhc.Discord.ApiError{status: 429, message: "rate limited"}},
      {:error, %Dhc.Discord.ApiError{status: 403, message: "forbidden"}},
      {:error, :timeout}
    ])

    params = %{name: "Roll call", auto_archive_duration: 1440}

    assert {:error, {:rate_limited, _}} =
             Dhc.Discord.create_thread_from_message("222", "111", params)

    assert {:error, {:permission, _}} =
             Dhc.Discord.create_thread_from_message("222", "111", params)

    assert {:error, {:timeout, _}} =
             Dhc.Discord.create_thread_from_message("222", "111", params)
  end

  test "success without a trustworthy id is ambiguous, never ok" do
    TestAdapter.script(:create_message, [{:ok, %{}}, {:ok, %{message_id: nil}}])
    TestAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: ""}}])

    params = %{content: "Hello", allowed_mentions: %{parse: []}}

    assert {:error, {:ambiguous, ": invalid Discord message response"}} =
             Dhc.Discord.create_message("222", params)

    assert {:error, {:ambiguous, _}} = Dhc.Discord.create_message("222", params)

    assert {:error, {:ambiguous, ": invalid Discord thread response"}} =
             Dhc.Discord.create_thread_from_message("222", "111", %{
               name: "Roll call",
               auto_archive_duration: 1440
             })
  end

  test "the live adapter rejects invalid snowflakes before making a request" do
    Application.put_env(:dhc, :discord_adapter, Dhc.Discord.Adapter.Nostrum)

    assert {:error, %Dhc.Discord.ApiError{status: 400}} =
             Dhc.Discord.Adapter.Nostrum.create_message("not-a-snowflake", %{
               content: "hi",
               allowed_mentions: %{parse: []}
             })

    assert {:error, {:payload_rejected, ": invalid Discord channel id"}} =
             Dhc.Discord.create_message("not-a-snowflake", %{
               content: "hi",
               allowed_mentions: %{parse: []}
             })

    assert {:error, %Dhc.Discord.ApiError{status: 400}} =
             Dhc.Discord.Adapter.Nostrum.create_thread_from_message(
               "123456789012345678",
               "not-a-snowflake",
               %{name: "Roll call", auto_archive_duration: 1440}
             )
  end

  test "the live adapter validates message and thread params locally" do
    Application.put_env(:dhc, :discord_adapter, Dhc.Discord.Adapter.Nostrum)

    assert {:error, %Dhc.Discord.ApiError{status: 400}} =
             Dhc.Discord.Adapter.Nostrum.create_message("123456789012345678", %{})

    assert {:error, %Dhc.Discord.ApiError{status: 400}} =
             Dhc.Discord.Adapter.Nostrum.create_thread_from_message(
               "123456789012345678",
               "123456789012345679",
               %{name: "Roll call", auto_archive_duration: 61}
             )
  end

  test "the development adapter posts nothing but returns ok shapes" do
    assert {:ok, %{message_id: message_id}} =
             Dhc.Discord.Adapter.Dev.create_message("guild-123", %{
               content: "hi",
               allowed_mentions: %{parse: ["everyone"]}
             })

    assert is_binary(message_id)

    assert {:ok, %{thread_id: thread_id}} =
             Dhc.Discord.Adapter.Dev.create_thread_from_message("guild-123", "111", %{
               name: "Roll call",
               auto_archive_duration: 1440
             })

    assert is_binary(thread_id)
  end

  defp restore_env(key, nil), do: Application.delete_env(:dhc, key)
  defp restore_env(key, value), do: Application.put_env(:dhc, key, value)
end
