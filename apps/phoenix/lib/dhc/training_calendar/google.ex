defmodule Dhc.TrainingCalendar.Google do
  @moduledoc """
  Google Calendar ACL transport for the training calendar roster.

  The transport exchanges its dedicated refresh token for every public
  operation. It deliberately exposes only closed outcomes: credentials,
  provider payloads, and transport exceptions do not escape this boundary.
  """

  @scope "https://www.googleapis.com/auth/calendar.acls"
  @token_url "https://oauth2.googleapis.com/token"
  @calendar_url "https://www.googleapis.com/calendar/v3"
  @max_results 250

  @type error :: :configuration | :unauthorized | :transient | :conflict | :rejected | :missing

  @doc "Lists every ACL rule on a calendar."
  @spec list(String.t()) :: {:ok, [map()]} | {:error, error()}
  def list(calendar_id) when is_binary(calendar_id) and calendar_id != "" do
    with {:ok, token} <- access_token() do
      list_pages(calendar_id, token, nil, MapSet.new(), [])
    end
  end

  def list(_calendar_id), do: {:error, :rejected}

  @doc "Grants a person reader access to a training calendar."
  @spec insert(String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def insert(calendar_id, email)
      when is_binary(calendar_id) and calendar_id != "" and is_binary(email) and email != "" do
    with {:ok, token} <- access_token(),
         {:ok, response} <-
           request(:post, acl_path(calendar_id), token,
             json: %{"role" => "reader", "scope" => %{"type" => "user", "value" => email}},
             params: [sendNotifications: true]
           ) do
      acl_response(response)
    end
  end

  def insert(_calendar_id, _email), do: {:error, :rejected}

  @doc "Deletes an ACL rule when its Google ETag still matches."
  @spec delete(String.t(), String.t(), String.t()) :: :ok | {:error, error()}
  def delete(calendar_id, rule_id, etag)
      when is_binary(calendar_id) and calendar_id != "" and is_binary(rule_id) and rule_id != "" and
             is_binary(etag) and etag != "" do
    with {:ok, token} <- access_token(),
         {:ok, response} <-
           request(:delete, rule_path(calendar_id, rule_id), token, headers: [{"if-match", etag}]) do
      case response do
        %Req.Response{status: status} when status in 200..299 -> :ok
        %Req.Response{status: status} when status in [404, 410] -> :ok
        response -> {:error, classify_calendar(response)}
      end
    end
  end

  def delete(_calendar_id, _rule_id, _etag), do: {:error, :rejected}

  defp list_pages(calendar_id, token, page_token, seen_tokens, rules) do
    params = [maxResults: @max_results] ++ if(page_token, do: [pageToken: page_token], else: [])

    with {:ok, response} <- request(:get, acl_path(calendar_id), token, params: params),
         {:ok, page, next_page_token} <- acl_list_response(response) do
      cond do
        is_nil(next_page_token) ->
          {:ok, rules ++ page}

        MapSet.member?(seen_tokens, next_page_token) ->
          {:error, :rejected}

        true ->
          list_pages(
            calendar_id,
            token,
            next_page_token,
            MapSet.put(seen_tokens, next_page_token),
            rules ++ page
          )
      end
    else
      {:error, :missing} -> {:error, :configuration}
      error -> error
    end
  end

  defp access_token do
    with {:ok, credentials} <- credentials(),
         {:ok, response} <- refresh(credentials) do
      token_response(response)
    end
  end

  defp credentials do
    config = Application.get_env(:dhc, Dhc.TrainingCalendar, [])

    case {Keyword.get(config, :client_id), Keyword.get(config, :client_secret),
          Keyword.get(config, :refresh_token)} do
      {client_id, client_secret, refresh_token}
      when is_binary(client_id) and client_id != "" and is_binary(client_secret) and
             client_secret != "" and is_binary(refresh_token) and refresh_token != "" ->
        {:ok, {client_id, client_secret, refresh_token}}

      _missing ->
        {:error, :configuration}
    end
  end

  defp refresh({client_id, client_secret, refresh_token}) do
    request_options(
      method: :post,
      url: @token_url,
      form: [
        grant_type: "refresh_token",
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token,
        scope: @scope
      ]
    )
    |> Req.request()
    |> transport_safe()
  rescue
    _exception -> {:error, :transient}
  end

  defp token_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    case body do
      %{"access_token" => token} when is_binary(token) and token != "" ->
        if valid_oauth_scope?(Map.get(body, "scope")),
          do: {:ok, token},
          else: {:error, :configuration}

      _invalid_body ->
        {:error, :configuration}
    end
  end

  defp token_response(%Req.Response{status: 400, body: %{"error" => "invalid_grant"}}),
    do: {:error, :unauthorized}

  defp token_response(%Req.Response{status: 401}), do: {:error, :unauthorized}

  defp token_response(%Req.Response{status: status}) when status in 429..599,
    do: {:error, :transient}

  defp token_response(%Req.Response{}), do: {:error, :configuration}

  defp request(method, path, token, options) do
    headers = [{"authorization", "Bearer #{token}"} | Keyword.get(options, :headers, [])]

    options
    |> Keyword.drop([:headers])
    |> Keyword.merge(method: method, base_url: @calendar_url, url: path, headers: headers)
    |> request_options()
    |> Req.request()
    |> transport_safe()
  rescue
    _exception -> {:error, :transient}
  end

  defp acl_list_response(%Req.Response{status: status, body: %{"kind" => "calendar#acl"} = body})
       when status in 200..299 do
    with {:ok, rules} <- acl_rules(Map.get(body, "items", [])),
         {:ok, page_token} <- next_page_token(Map.get(body, "nextPageToken")) do
      {:ok, rules, page_token}
    end
  end

  defp acl_list_response(%Req.Response{status: status}) when status in 200..299,
    do: {:error, :rejected}

  defp acl_list_response(response), do: {:error, classify_calendar(response)}

  defp acl_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    case valid_acl_rule?(body) do
      true -> {:ok, body}
      # A successful insertion with an unusable acknowledgment may still have
      # created the rule. Keep the caller's unacknowledged grant for read-back.
      false -> {:error, :transient}
    end
  end

  defp acl_response(response), do: {:error, classify_calendar(response)}

  defp acl_rules(rules) when is_list(rules) do
    if Enum.all?(rules, &valid_acl_rule?/1), do: {:ok, rules}, else: {:error, :rejected}
  end

  defp acl_rules(_rules), do: {:error, :rejected}

  defp valid_acl_rule?(%{"id" => id, "etag" => etag, "scope" => scope, "role" => role}) do
    nonblank?(id) and nonblank?(etag) and valid_acl_scope?(scope) and
      role in [
        "none",
        "freeBusyReader",
        "reader",
        "writerWithoutPrivateAccess",
        "writer",
        "owner"
      ]
  end

  defp valid_acl_rule?(_rule), do: false

  defp valid_acl_scope?(%{"type" => "default"}), do: true

  defp valid_acl_scope?(%{"type" => type, "value" => value})
       when type in ["user", "group", "domain"],
       do: nonblank?(value)

  defp valid_acl_scope?(_scope), do: false

  defp next_page_token(nil), do: {:ok, nil}
  defp next_page_token(token) when is_binary(token) and token != "", do: {:ok, token}
  defp next_page_token(_token), do: {:error, :rejected}

  defp classify_calendar(%Req.Response{status: 401}), do: :unauthorized

  defp classify_calendar(%Req.Response{status: 403, body: body}),
    do: if(rate_limited?(body), do: :transient, else: :configuration)

  defp classify_calendar(%Req.Response{status: status}) when status in [404, 410], do: :missing
  defp classify_calendar(%Req.Response{status: status}) when status in [409, 412], do: :conflict

  defp classify_calendar(%Req.Response{status: status}) when status == 429 or status in 500..599,
    do: :transient

  defp classify_calendar(%Req.Response{}), do: :rejected

  defp rate_limited?(%{"error" => %{"errors" => errors}}) when is_list(errors) do
    Enum.any?(errors, fn
      %{"reason" => reason} when reason in ["rateLimitExceeded", "userRateLimitExceeded"] -> true
      _error -> false
    end)
  end

  defp rate_limited?(_body), do: false

  defp valid_oauth_scope?(nil), do: true

  defp valid_oauth_scope?(scope) when is_binary(scope),
    do: String.split(scope, " ", trim: true) == [@scope]

  defp valid_oauth_scope?(_scope), do: false

  defp acl_path(calendar_id), do: "/calendars/#{segment(calendar_id)}/acl"
  defp rule_path(calendar_id, rule_id), do: "#{acl_path(calendar_id)}/#{segment(rule_id)}"
  defp segment(value), do: URI.encode_www_form(value)
  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_value), do: false

  defp request_options(options) do
    config = Application.get_env(:dhc, Dhc.TrainingCalendar, [])

    Keyword.get(config, :req_options, [])
    |> Keyword.merge(options)
    |> Keyword.merge(
      retry: false,
      retry_log_level: false,
      redirect: false,
      receive_timeout: 30_000,
      connect_options: [timeout: 30_000]
    )
  end

  defp transport_safe({:error, _exception}), do: {:error, :transient}
  defp transport_safe(result), do: result
end
