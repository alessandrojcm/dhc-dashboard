defmodule Dhc.WorkshopCalendar.Google do
  @moduledoc """
  Google Calendar event transport for the two organizer calendars.

  Each operation obtains a token from the shared GoogleCalendar.Auth module,
  then makes exactly one Calendar request. This module never retries: callers own retry and
  reconciliation. Provider responses and transport exceptions are deliberately
  collapsed into closed atoms so credentials and provider bodies never become
  logs, errors, or exception metadata.
  """

  alias Dhc.GoogleCalendar.Auth

  @calendar_url "https://www.googleapis.com/calendar/v3"

  @type error ::
          Auth.error() | :missing | :gone | :unauthorized | :conflict | :rejected

  @doc "Gets an event from an organizer calendar."
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def get(calendar_id, event_id) do
    with {:ok, token} <- Auth.access_token(),
         {:ok, response} <- request(:get, event_path(calendar_id, event_id), token) do
      event_response(response)
    end
  end

  @doc "Checks that the organizer credential can read the configured calendar."
  @spec check_calendar(String.t()) :: :ok | {:error, error()}
  def check_calendar(calendar_id) do
    with {:ok, token} <- Auth.access_token(),
         {:ok, response} <-
           request(:get, events_path(calendar_id), token, params: [maxResults: 1, fields: "kind"]) do
      calendar_check_response(response)
    end
  end

  @doc "Creates a committee-only event without notifying attendees."
  @spec insert(String.t(), map()) :: {:ok, map()} | {:error, error()} | term()
  @spec insert(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()} | term()
  def insert(calendar_id, event, opts \\ [])

  def insert(calendar_id, event, opts) when is_map(event) and is_list(opts) do
    with :ok <- audience_event(event, opts),
         {:ok, token} <- Auth.access_token(),
         :ok <- before_mutation(opts),
         {:ok, response} <-
           request(:post, events_path(calendar_id), token,
             json: event,
             send_updates: updates(opts)
           ) do
      event_response(response)
    end
  end

  def insert(_calendar_id, _event, _opts), do: {:error, :rejected}

  @doc "Replaces an event only when its Google ETag still matches."
  @spec update(String.t(), String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, error()} | term()
  @spec update(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, error()} | term()
  def update(calendar_id, event_id, event, etag, opts \\ [])

  def update(calendar_id, event_id, event, etag, opts)
      when is_map(event) and is_binary(etag) and is_list(opts) do
    with :ok <- audience_event(event, opts),
         {:ok, token} <- Auth.access_token(),
         :ok <- before_mutation(opts),
         {:ok, response} <-
           request(:put, event_path(calendar_id, event_id), token,
             json: event,
             headers: [{"if-match", etag}],
             send_updates: updates(opts)
           ) do
      event_response(response)
    end
  end

  def update(_calendar_id, _event_id, _event, _etag, _opts), do: {:error, :rejected}

  @doc "Deletes an event only when its Google ETag still matches."
  @spec delete(String.t(), String.t(), String.t()) ::
          {:ok, map() | :deleted} | {:error, error()} | term()
  @spec delete(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map() | :deleted} | {:error, error()} | term()
  def delete(calendar_id, event_id, etag, opts \\ [])

  def delete(calendar_id, event_id, etag, opts) when is_binary(etag) and is_list(opts) do
    with {:ok, token} <- Auth.access_token(),
         :ok <- before_mutation(opts),
         {:ok, response} <-
           request(:delete, event_path(calendar_id, event_id), token,
             headers: [{"if-match", etag}],
             send_updates: updates(opts)
           ) do
      case response do
        %Req.Response{status: status} when status in 200..299 -> {:ok, :deleted}
        response -> {:error, classify_calendar(response)}
      end
    end
  end

  def delete(_calendar_id, _event_id, _etag, _opts), do: {:error, :rejected}

  defp request(method, path, token, options \\ []) do
    headers = [{"authorization", "Bearer #{token}"} | Keyword.get(options, :headers, [])]
    send_updates = Keyword.get(options, :send_updates)

    options
    |> Keyword.drop([:headers, :send_updates])
    |> Keyword.merge(method: method, base_url: @calendar_url, url: path, headers: headers)
    |> maybe_send_updates(send_updates)
    |> request_options()
    |> Req.request()
    |> transport_safe()
  rescue
    _exception -> {:error, :transient}
  end

  defp event_response(%Req.Response{status: status, body: body})
       when status in 200..299 and is_map(body),
       do: {:ok, body}

  defp event_response(%Req.Response{status: status}) when status in 200..299,
    do: {:error, :rejected}

  defp event_response(response), do: {:error, classify_calendar(response)}

  defp calendar_check_response(%Req.Response{status: status, body: body})
       when status in 200..299 and is_map(body),
       do: :ok

  defp calendar_check_response(%Req.Response{status: status}) when status in 200..299,
    do: {:error, :rejected}

  defp calendar_check_response(response) do
    case classify_calendar(response) do
      reason when reason in [:missing, :gone] -> {:error, :configuration}
      reason -> {:error, reason}
    end
  end

  defp classify_calendar(%Req.Response{status: 401}), do: :unauthorized

  defp classify_calendar(%Req.Response{status: 403, body: body}),
    do: if(rate_limited?(body), do: :transient, else: :configuration)

  defp classify_calendar(%Req.Response{status: 404}), do: :missing
  defp classify_calendar(%Req.Response{status: 410}), do: :gone
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

  defp updates(opts) do
    if Keyword.get(opts, :audience) == :participant,
      do: Keyword.get(opts, :send_updates, "all"),
      else: "none"
  end

  defp audience_event(event, opts) do
    if Keyword.get(opts, :audience) == :participant,
      do: :ok,
      else: committee_event(event)
  end

  defp committee_event(%{"attendees" => []}), do: :ok
  defp committee_event(%{attendees: []}), do: :ok

  defp committee_event(event) when is_map(event),
    do: if(has_attendees?(event), do: {:error, :rejected}, else: :ok)

  defp has_attendees?(event),
    do: Map.has_key?(event, "attendees") or Map.has_key?(event, :attendees)

  defp before_mutation(opts) do
    case Keyword.get(opts, :before_mutation, fn -> :ok end) do
      callback when is_function(callback, 0) -> callback.()
      _not_a_callback -> {:error, :rejected}
    end
  end

  defp events_path(calendar_id), do: "/calendars/#{segment(calendar_id)}/events"
  defp event_path(calendar_id, event_id), do: "#{events_path(calendar_id)}/#{segment(event_id)}"
  defp segment(value) when is_binary(value), do: URI.encode_www_form(value)
  defp segment(_value), do: ""

  defp request_options(options) do
    config = Application.get_env(:dhc, Dhc.WorkshopCalendar, [])

    Keyword.get(config, :req_options, [])
    |> Keyword.merge(options)
    |> Keyword.merge(retry: false, retry_log_level: false, redirect: false)
  end

  defp transport_safe({:error, _exception}), do: {:error, :transient}
  defp transport_safe(result), do: result

  defp maybe_send_updates(options, nil), do: options

  defp maybe_send_updates(options, send_updates),
    do: Keyword.put(options, :params, sendUpdates: send_updates)
end
