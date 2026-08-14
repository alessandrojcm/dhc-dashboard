defmodule Dhc.Discord.RosterClient do
  @moduledoc false

  @base_url "https://discord.com/api/v10"

  def application(token, request_options),
    do: request("/oauth2/applications/@me", token, [], request_options)

  def members(token, guild_id, cursor, limit, request_options) do
    params = [limit: limit] ++ if(cursor, do: [after: cursor], else: [])
    request("/guilds/#{URI.encode(guild_id)}/members", token, params, request_options)
  end

  defp request(path, token, params, request_options) do
    request_options =
      Keyword.merge(request_options,
        headers: [{"authorization", "Bot #{token}"}],
        params: params,
        retry: false
      )

    case Req.get(@base_url <> path, request_options) do
      {:ok, %Req.Response{} = response} ->
        {:ok, %{status: response.status, headers: response.headers, body: response.body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end
end
