defmodule Dhc.GoogleCalendar.Auth do
  @moduledoc """
  The organizer's shared Google Calendar connection.

  Only the Calendar HTTP adapters consume access tokens. Configuration, refresh
  exchanges and scope validation live here, not in either Calendar workflow.
  The grant permits owned-event operations and ACL operations on the organizer's
  calendars; application target selection is not provider-enforced isolation.
  Tokens are exchanged per operation, never persisted, logged or cached.
  """

  @token_url "https://oauth2.googleapis.com/token"
  @scopes MapSet.new([
            "https://www.googleapis.com/auth/calendar.events.owned",
            "https://www.googleapis.com/auth/calendar.acls"
          ])

  @type error ::
          :configuration
          | :invalid_client
          | :reauthorization_required
          | :missing_permissions
          | :unexpected_permissions
          | :transient

  @doc "Exchanges the configured organizer grant for a validated short-lived token."
  @spec access_token() :: {:ok, String.t()} | {:error, error()}
  def access_token do
    config = Application.get_env(:dhc, __MODULE__, [])

    with {:ok, _client_id} <- client_id() do
      config
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        method: :post,
        url: @token_url,
        form: [
          grant_type: "refresh_token",
          client_id: config[:client_id],
          client_secret: config[:client_secret],
          refresh_token: config[:refresh_token]
        ],
        retry: false,
        retry_log_level: false,
        redirect: false,
        receive_timeout: 30_000,
        connect_options: [timeout: 30_000]
      )
      |> Req.request()
      |> token_response()
    end
  rescue
    _exception -> {:error, :transient}
  end

  @doc "Verifies the running process's connection without returning a credential."
  @spec check() :: :ok | {:error, error()}
  def check do
    with {:ok, _token} <- access_token(), do: :ok
  end

  defp token_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    with %{"access_token" => token} when is_binary(token) and token != "" <- body,
         :ok <- validate_scopes(Map.get(body, "scope")) do
      {:ok, token}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :configuration}
    end
  end

  defp token_response({:ok, %Req.Response{status: status}})
       when status == 429 or status in 500..599,
       do: {:error, :transient}

  defp token_response({:ok, %Req.Response{body: %{"error" => error}}}) do
    case error do
      "invalid_client" -> {:error, :invalid_client}
      "deleted_client" -> {:error, :invalid_client}
      "unauthorized_client" -> {:error, :invalid_client}
      "invalid_grant" -> {:error, :reauthorization_required}
      "access_denied" -> {:error, :reauthorization_required}
      "invalid_scope" -> {:error, :missing_permissions}
      _unknown -> {:error, :configuration}
    end
  end

  defp token_response({:ok, %Req.Response{status: 401}}), do: {:error, :invalid_client}
  defp token_response({:ok, %Req.Response{}}), do: {:error, :configuration}
  defp token_response({:error, _exception}), do: {:error, :transient}

  defp validate_scopes(scope) when is_binary(scope) do
    granted = scope |> String.split() |> MapSet.new()

    cond do
      not MapSet.subset?(@scopes, granted) -> {:error, :missing_permissions}
      granted != @scopes -> {:error, :unexpected_permissions}
      true -> :ok
    end
  end

  defp validate_scopes(_scope), do: {:error, :missing_permissions}

  @doc "Returns the non-secret client identity only when all credentials are configured."
  @spec client_id() :: {:ok, String.t()} | {:error, :configuration}
  def client_id do
    config = Application.get_env(:dhc, __MODULE__, [])

    if Enum.all?([:client_id, :client_secret, :refresh_token], &nonblank?(config[&1])),
      do: {:ok, config[:client_id]},
      else: {:error, :configuration}
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
