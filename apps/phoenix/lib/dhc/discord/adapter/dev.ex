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
end
