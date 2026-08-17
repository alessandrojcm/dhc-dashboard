defmodule Dhc.Discord do
  @moduledoc """
  Discord server operations owned by the application.

  Callers use this context instead of depending on a Discord client library.
  """

  @spec list_guild_members() :: Dhc.Discord.Adapter.list_members_result()
  def list_guild_members do
    adapter().list_guild_members(guild_id())
  end

  @spec add_guild_member(String.t(), String.t()) :: Dhc.Discord.Adapter.add_member_result()
  def add_guild_member(user_id, access_token) do
    adapter().add_guild_member(guild_id(), user_id, access_token)
  end

  @spec kick_guild_member(String.t(), String.t()) :: Dhc.Discord.Adapter.kick_member_result()
  def kick_guild_member(user_id, reason) do
    adapter().kick_guild_member(guild_id(), user_id, reason)
  end

  defp adapter, do: Application.fetch_env!(:dhc, :discord_adapter)
  defp guild_id, do: Application.fetch_env!(:dhc, :discord_guild_id)
end
