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

  defp restore_env(key, nil), do: Application.delete_env(:dhc, key)
  defp restore_env(key, value), do: Application.put_env(:dhc, key, value)
end
