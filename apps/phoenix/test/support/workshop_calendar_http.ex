defmodule Dhc.WorkshopCalendarHTTP do
  @moduledoc "An organizer-owned Google HTTP surface, substituted only through Req.Test."

  import ExUnit.Assertions

  alias Dhc.WorkshopCalendar.Google

  def stub(server, before_request \\ fn _conn -> :ok end) do
    Req.Test.stub(Google, fn conn ->
      before_request.(conn)
      respond(server, conn)
    end)
  end

  def initial do
    %{
      events: %{},
      requests: [],
      sequence: 0,
      status: nil,
      insert_conflict: false,
      uncertain_insert: false,
      defer_insert: false,
      delayed: nil,
      revoked: false
    }
  end

  def events(server), do: Agent.get(server, & &1.events)
  def requests(server), do: Agent.get(server, &Enum.reverse(&1.requests))

  def mutations(server) do
    server |> requests() |> Enum.filter(&(&1.method != "GET" and &1.host == "www.googleapis.com"))
  end

  defp respond(server, conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    payload =
      if body == "" or conn.host == "oauth2.googleapis.com", do: nil, else: Jason.decode!(body)

    request = %{
      method: conn.method,
      host: conn.host,
      path: conn.request_path,
      query: conn.query_string,
      payload: payload,
      if_match: Plug.Conn.get_req_header(conn, "if-match")
    }

    response = Agent.get_and_update(server, &route(&1, request))

    case response do
      {:json, status, value} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(value)
      :timeout -> Req.Test.transport_error(conn, :timeout)
    end
  end

  defp route(state, request) do
    state = %{state | requests: [request | state.requests]}

    cond do
      request.host == "oauth2.googleapis.com" and state.revoked ->
        {{:json, 400,
          %{"error" => "invalid_grant", "error_description" => "PRIVATE provider body"}}, state}

      request.host == "oauth2.googleapis.com" ->
        {{:json, 200, %{access_token: "isolated-access", token_type: "Bearer"}}, state}

      state.status ->
        {{:json, state.status, %{error: %{message: "PRIVATE provider body"}}}, state}

      true ->
        event_request(state, request)
    end
  end

  defp event_request(state, %{method: "POST", payload: event}) do
    assert event["attendees"] in [nil, []]
    id = event["id"]

    cond do
      state.insert_conflict ->
        {{:json, 409, %{}}, state}

      Map.has_key?(state.events, id) ->
        {{:json, 409, %{}}, state}

      state.defer_insert ->
        {event, state} = stamp(state, event)
        {:timeout, %{state | delayed: event, defer_insert: false}}

      true ->
        {event, state} = stamp(state, event)
        next = %{state | events: Map.put(state.events, id, event), uncertain_insert: false}
        response = if state.uncertain_insert, do: :timeout, else: {:json, 200, event}
        {response, next}
    end
  end

  defp event_request(state, request) do
    id = request.path |> String.split("/") |> List.last()

    case {request.method, Map.get(state.events, id)} do
      {"GET", nil} when id == "events" ->
        {{:json, 200, %{"kind" => "calendar#events"}}, state}

      {_method, nil} ->
        {{:json, 404, %{}}, state}

      {"GET", event} ->
        {{:json, 200, event}, state}

      {_method, %{"status" => "cancelled"}} ->
        {{:json, 410, %{}}, state}

      {method, event} when method in ["PUT", "PATCH", "DELETE"] ->
        mutate(state, request, event, id)
    end
  end

  defp mutate(state, request, event, id) do
    if request.if_match == [event["etag"]] do
      replacement =
        if request.method == "DELETE",
          do: %{"id" => id, "status" => "cancelled"},
          else: request.payload

      {updated, state} = stamp(state, replacement)
      {{:json, 200, updated}, %{state | events: Map.put(state.events, id, updated)}}
    else
      {{:json, 412, %{}}, state}
    end
  end

  defp stamp(state, event) do
    sequence = state.sequence + 1
    {Map.put(event, "etag", "\"#{sequence}\""), %{state | sequence: sequence}}
  end
end
