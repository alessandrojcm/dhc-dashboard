defmodule Dhc.Discord.Adapter.Dev do
  @moduledoc """
  Prevents local development from mutating the real Discord guild.

  Discord sign-in and account-linking OAuth remain live. Invitation onboarding
  may use the separate development OAuth bypass, while guild membership
  operations always stop at this adapter.
  """

  @behaviour Dhc.Discord.Adapter

  require Logger

  @impl true
  def list_guild_members(_guild_id), do: {:ok, []}

  @impl true
  def add_guild_member(_guild_id, user_id, _access_token, nickname) do
    Logger.info(
      "[discord-dev] skipped guild join for #{user_id} with nickname #{inspect(nickname)}"
    )

    {:ok, :added}
  end

  @impl true
  def kick_guild_member(_guild_id, user_id, reason) do
    Logger.info("[discord-dev] skipped guild kick for #{user_id}: #{inspect(reason)}")
    :ok
  end

  @impl true
  def create_message(channel_id, params) when is_map(params) do
    Logger.info(
      "[discord-dev] skipped message create in #{channel_id}: #{inspect(Map.get(params, :content))}"
    )

    {:ok, %{message_id: "dev-message-id"}}
  end

  @impl true
  def create_thread_from_message(channel_id, message_id, params) when is_map(params) do
    Logger.info(
      "[discord-dev] skipped thread create in #{channel_id} for #{message_id}: #{inspect(Map.get(params, :name))}"
    )

    {:ok, %{thread_id: "dev-thread-id"}}
  end
end
