defmodule Dhc.Discord.OAuthDevStub do
  @moduledoc false

  @behaviour Assent.Strategy

  @callback_code "dev-success"

  @impl true
  def authorize_url(config) do
    with :ok <- ensure_development(),
         redirect_uri when is_binary(redirect_uri) <- Keyword.get(config, :redirect_uri),
         {:ok, uri} <- URI.new(redirect_uri) do
      state = random_token()

      query =
        uri.query
        |> decode_query()
        |> Map.merge(%{"code" => @callback_code, "state" => state})
        |> URI.encode_query()

      {:ok,
       %{
         url: uri |> Map.put(:query, query) |> URI.to_string(),
         session_params: %{dev_bypass: true, state: state}
       }}
    else
      _unavailable -> {:error, :development_bypass_unavailable}
    end
  end

  @impl true
  def callback(config, %{"code" => @callback_code, "state" => state}) do
    with :ok <- ensure_development(),
         %{dev_bypass: true, state: expected_state} when is_binary(expected_state) <-
           Keyword.get(config, :session_params),
         true <- secure_match?(expected_state, state) do
      {:ok,
       %{
         user: %{
           "sub" => "development-invitation-#{subject_suffix(state)}",
           "email" => "development-invitation@localhost",
           "email_verified" => true,
           "preferred_username" => "Local development member"
         },
         token: %{
           "access_token" => "development-invitation-acceptance-token",
           "expires_in" => 604_800
         }
       }}
    else
      _invalid_callback -> {:error, :invalid_callback}
    end
  end

  def callback(_config, _params), do: {:error, :invalid_callback}

  defp ensure_development do
    if Application.get_env(:dhc, :environment) == :development,
      do: :ok,
      else: {:error, :not_development}
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)

  defp random_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp secure_match?(expected, actual)
       when is_binary(expected) and is_binary(actual) and byte_size(expected) == byte_size(actual),
       do: Plug.Crypto.secure_compare(expected, actual)

  defp secure_match?(_expected, _actual), do: false

  defp subject_suffix(state) do
    :sha256
    |> :crypto.hash(state)
    |> Base.url_encode64(padding: false)
  end
end
