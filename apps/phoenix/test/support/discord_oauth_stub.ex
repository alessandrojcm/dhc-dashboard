defmodule Dhc.DiscordOAuthStub do
  @moduledoc false

  @behaviour Assent.Strategy

  @impl true
  def authorize_url(_config) do
    {:ok,
     %{
       url: "https://discord.example.com/oauth2/authorize?state=test-state",
       session_params: %{state: "test-state"}
     }}
  end

  @impl true
  def callback(config, %{"state" => "test-state", "code" => code}) do
    case {Keyword.get(config, :session_params), code} do
      {%{state: "test-state"}, "success"} ->
        {:ok,
         %{
           user: %{
             "sub" => "discord-request-success",
             "email" => "discord-request@example.com",
             "email_verified" => true,
             "preferred_username" => "request-member"
           },
           token: %{"access_token" => "not-persisted"}
         }}

      {%{state: "test-state"}, "unknown"} ->
        {:ok,
         %{
           user: %{
             "sub" => "discord-request-unknown",
             "email" => "unknown-discord@example.com",
             "email_verified" => true
           },
           token: %{"access_token" => "not-persisted"}
         }}

      _ ->
        {:error, :invalid_callback}
    end
  end

  def callback(_config, _params), do: {:error, :invalid_callback}
end
