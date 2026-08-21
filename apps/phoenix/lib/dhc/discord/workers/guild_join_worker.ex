defmodule Dhc.Discord.Workers.GuildJoinWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :discord,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias Dhc.Discord
  alias Dhc.Discord.ApiError

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"grant_id" => grant_id}}) do
    case Discord.prepare_guild_join(grant_id) do
      {:ok, join} -> add_member(join)
      {:terminal, _reason} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_member(join) do
    case Discord.add_guild_member(join.user_id, join.access_token, join.nickname) do
      {:ok, outcome} when outcome in [:added, :already_member] -> zeroize(join.grant)
      {:error, %ApiError{status: status}} when status in [401, 403] -> zeroize(join.grant)
      {:error, reason} -> {:error, reason}
    end
  end

  defp zeroize(grant) do
    case Discord.zeroize_join_grant(grant) do
      {:ok, _grant} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end
end
