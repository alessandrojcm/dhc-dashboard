defmodule Dhc.Discord.Adapter.Test do
  @moduledoc false

  @behaviour Dhc.Discord.Adapter

  use Agent

  def start_link(options) do
    owner = Keyword.fetch!(options, :owner)
    Agent.start_link(fn -> %{owner: owner, scripts: %{}} end, name: __MODULE__)
  end

  def script(operation, outcomes) when is_list(outcomes) do
    Agent.update(__MODULE__, &put_in(&1, [:scripts, operation], outcomes))
  end

  @impl true
  def list_guild_members(guild_id) do
    record_and_pop(:list_guild_members, [guild_id])
  end

  @impl true
  def add_guild_member(guild_id, user_id, access_token) do
    record_and_pop(:add_guild_member, [guild_id, user_id, access_token])
  end

  @impl true
  def kick_guild_member(guild_id, user_id, reason) do
    record_and_pop(:kick_guild_member, [guild_id, user_id, reason])
  end

  defp record_and_pop(operation, arguments) do
    Agent.get_and_update(__MODULE__, fn state ->
      send(state.owner, {operation, arguments})

      case Map.get(state.scripts, operation, []) do
        [outcome | remaining] ->
          {outcome, put_in(state, [:scripts, operation], remaining)}

        [] ->
          raise "no scripted Discord adapter outcome for #{operation}"
      end
    end)
  end
end
