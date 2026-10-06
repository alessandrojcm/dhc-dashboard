defmodule Dhc.StripeHTTPStub do
  @moduledoc """
  Method/path router over the one Stripe transport seam (ALE-342).

  `config/test.exs` points `Dhc.Stripe.Client` at `plug: {Req.Test, Dhc.Stripe}`,
  so every Stripe HTTP call in a test is answered in-process by whatever the
  test registered under `Dhc.Stripe`. `Req.Test` keeps a single plug per name,
  so this module keeps the test's routes and re-registers one dispatching plug
  each time a route is added:

      Dhc.StripeHTTPStub.expect("POST", "/v1/subscriptions", fn conn ->
        assert Dhc.StripeHTTPStub.form(conn)["customer"] == "cus_1"
        Dhc.StripeHTTPStub.json(conn, %{"id" => "sub_1"})
      end)

  * `stub/3` answers a route any number of times.
  * `expect/4` answers it at most `n` times and fails the test on exit unless
    it was called exactly `n` times. Adding a route for the same method and
    path replaces the earlier one (and its expectation), as Bypass did.
  * A request no route matches raises in the calling process, so an
    unexpected Stripe call fails the test instead of reaching the network.

  Routes are owned by the test process (the one that registered them) and
  follow `Req.Test` ownership: requests made from that process, its Tasks
  (`Task.async_stream` previews), and other `$callers` descendants see them.
  A process outside that tree needs `Req.Test.allow(Dhc.Stripe, test_pid, pid)`.
  Routes must therefore be registered from the test process or its `setup`,
  never from `setup_all`.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @name Dhc.Stripe
  @routes {__MODULE__, :routes}

  @doc "The `Req.Test` stub name `Dhc.Stripe.Client` uses in tests."
  def name, do: @name

  @doc "Answers every `method path` request with `plug`."
  def stub(method, path, plug) when is_function(plug, 1),
    do: add_route(method, path, plug, :infinity)

  @doc "Answers exactly `n` `method path` requests with `plug`; verified on test exit."
  def expect(method, path, n \\ 1, plug) when is_integer(n) and n > 0 and is_function(plug, 1),
    do: add_route(method, path, plug, n)

  @doc "Sends a JSON response, `200` unless `status` is given."
  def json(conn, status \\ 200, body) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(body)
  end

  @doc "Sends a Stripe-shaped error object."
  def stripe_error(conn, status, error \\ %{}) do
    json(conn, status, %{"error" => Map.merge(%{"type" => "invalid_request_error"}, error)})
  end

  @doc "Simulates a transport failure (e.g. `:econnrefused`, `:timeout`)."
  def transport_error(conn, reason), do: Req.Test.transport_error(conn, reason)

  @doc """
  The form-encoded request body as a flat map (`"metadata[kind]" => "monthly"`),
  matching what Stripe receives. A repeated key keeps its last value.
  """
  def form(conn) do
    conn
    |> Req.Test.raw_body()
    |> IO.iodata_to_binary()
    |> URI.decode_query()
  end

  @doc "The query string as a flat map (`\"expand[]\" => \"data.latest_invoice\"`)."
  def query(conn), do: URI.decode_query(conn.query_string)

  @doc "The query string as an ordered list of pairs, keeping repeated keys."
  def query_pairs(conn), do: conn.query_string |> URI.query_decoder() |> Enum.to_list()

  @doc "The first value of a request header."
  def header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defp add_route(method, path, plug, limit) do
    key = {String.upcase(to_string(method)), path}
    routes = Process.get(@routes, %{})

    with %{counter: previous} <- routes[key], do: :counters.put(previous, 2, 1)

    # Slot 1 counts calls; slot 2 marks the route superseded by a later one.
    counter = :counters.new(2, [:atomics])
    routes = Map.put(routes, key, %{plug: plug, limit: limit, counter: counter})
    Process.put(@routes, routes)

    if is_integer(limit), do: verify_on_exit(key, limit, counter)

    Req.Test.stub(@name, fn conn -> dispatch(conn, routes) end)
  end

  defp dispatch(conn, routes) do
    key = {conn.method, conn.request_path}

    case Map.fetch(routes, key) do
      {:ok, %{plug: plug, limit: limit, counter: counter}} ->
        :counters.add(counter, 1, 1)
        calls = :counters.get(counter, 1)

        if limit != :infinity and calls > limit do
          raise "Stripe stub #{conn.method} #{conn.request_path} expected #{limit} call(s), " <>
                  "got #{calls}"
        end

        plug.(conn)

      :error ->
        raise "unexpected Stripe request #{conn.method} #{conn.request_path}" <>
                if(conn.query_string == "", do: "", else: "?#{conn.query_string}")
    end
  end

  defp verify_on_exit({method, path}, limit, counter) do
    ExUnit.Callbacks.on_exit({__MODULE__, make_ref()}, fn ->
      calls = :counters.get(counter, 1)
      superseded? = :counters.get(counter, 2) == 1

      unless superseded? or calls == limit do
        flunk("Stripe stub #{method} #{path} expected #{limit} call(s), got #{calls}")
      end
    end)
  end
end
