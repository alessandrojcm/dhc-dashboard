defmodule Dhc.DiscordOAuthStub do
  @moduledoc false

  @behaviour Assent.Strategy

  def fail_next_authorization do
    Process.put({__MODULE__, :fail_next_authorization}, true)
  end

  @impl true
  def authorize_url(config) do
    if Process.delete({__MODULE__, :fail_next_authorization}) do
      {:error, :authorization_failed}
    else
      authorization_number = Process.get({__MODULE__, :authorization_number}, 0) + 1
      Process.put({__MODULE__, :authorization_number}, authorization_number)

      {state, code_verifier} = authorization_params(authorization_number)

      query =
        %{state: state}
        |> maybe_put_redirect_uri(Keyword.get(config, :redirect_uri))
        |> maybe_put_scope(get_in(config, [:authorization_params, :scope]))
        |> URI.encode_query()

      {:ok,
       %{
         url: "https://discord.example.com/oauth2/authorize?#{query}",
         session_params: %{state: state, code_verifier: code_verifier}
       }}
    end
  end

  defp maybe_put_redirect_uri(query, nil), do: query

  defp maybe_put_redirect_uri(query, redirect_uri),
    do: Map.put(query, :redirect_uri, redirect_uri)

  defp maybe_put_scope(query, nil), do: query
  defp maybe_put_scope(query, scope), do: Map.put(query, :scope, scope)

  @impl true
  def callback(_config, %{"error" => _error}), do: {:error, :provider_error}

  def callback(config, %{"state" => state, "code" => code}) do
    case {valid_session_params?(Keyword.get(config, :session_params), state), code} do
      {true, "success"} ->
        {:ok,
         %{
           user: %{
             "sub" => "discord-request-success",
             "email" => "discord-request@example.com",
             "email_verified" => true,
             "preferred_username" => "request-member",
             "picture" => "https://cdn.discord.example.com/avatars/request-member.png"
           },
           token: %{
             "access_token" => "acceptance-access-token",
             "expires_in" => 604_800,
             "refresh_token" => "must-never-be-persisted"
           }
         }}

      {true, "unknown"} ->
        {:ok,
         %{
           user: %{
             "sub" => "discord-request-unknown",
             "email" => "unknown-discord@example.com",
             "email_verified" => true
           },
           token: %{
             "access_token" => "unknown-access-token",
             "expires_in" => 604_800,
             "refresh_token" => "must-never-be-persisted"
           }
         }}

      _ ->
        {:error, :invalid_callback}
    end
  end

  def callback(_config, _params), do: {:error, :invalid_callback}

  defp authorization_params(1), do: {"test-state", "test-code-verifier"}

  defp authorization_params(number) do
    {"test-state-#{number}", "test-code-verifier-#{number}"}
  end

  defp valid_session_params?(%{state: state, code_verifier: code_verifier}, callback_state) do
    state == callback_state and code_verifier == expected_code_verifier(state)
  end

  defp valid_session_params?(_session_params, _callback_state), do: false

  defp expected_code_verifier("test-state"), do: "test-code-verifier"

  defp expected_code_verifier(state) do
    case String.split(state, "test-state-", parts: 2) do
      ["", number] -> "test-code-verifier-#{number}"
      _invalid -> nil
    end
  end
end
