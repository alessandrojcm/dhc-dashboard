defmodule Dhc.Discord.RosterClient do
  @moduledoc false

  @base_url "https://discord.com/api/v10"

  def application(token), do: request("/oauth2/applications/@me", token, [])

  def members(token, guild_id, cursor) do
    params = [limit: 1000] ++ if(cursor, do: [after: cursor], else: [])
    request("/guilds/#{URI.encode(guild_id)}/members", token, params)
  end

  defp request(path, token, params) do
    case Req.get(@base_url <> path, headers: [{"authorization", "Bot #{token}"}], params: params) do
      {:ok, %Req.Response{} = response} ->
        {:ok, %{status: response.status, headers: response.headers, body: response.body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end
end
