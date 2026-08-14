defmodule Dhc.DiscordOAuthStub do
  @moduledoc false

  @behaviour Assent.Strategy

  @impl true
  def authorize_url(config) do
    query =
      %{state: "test-state"}
      |> maybe_put_redirect_uri(Keyword.get(config, :redirect_uri))
      |> URI.encode_query()

    {:ok,
     %{
       url: "https://discord.example.com/oauth2/authorize?#{query}",
       session_params: %{state: "test-state", code_verifier: "test-code-verifier"}
     }}
  end

  defp maybe_put_redirect_uri(query, nil), do: query

  defp maybe_put_redirect_uri(query, redirect_uri),
    do: Map.put(query, :redirect_uri, redirect_uri)

  @impl true
  def callback(config, %{"state" => "test-state", "code" => code}) do
    case {Keyword.get(config, :session_params), code} do
      {%{state: "test-state", code_verifier: "test-code-verifier"}, "success"} ->
        {:ok,
         %{
           user: %{
             "sub" => "discord-request-success",
             "email" => "discord-request@example.com",
             "email_verified" => true,
             "preferred_username" => "request-member",
             "picture" => "https://cdn.discord.example.com/avatars/request-member.png"
           },
           token: %{"access_token" => "not-persisted"}
         }}

      {%{state: "test-state", code_verifier: "test-code-verifier"}, "unknown"} ->
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
