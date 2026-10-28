defmodule Dhc.Stripe.Client do
  @moduledoc """
  HTTP client adapter for the generated Stripe API modules.

  Every generated operation function calls `client.request/1`, delegating
  to this module. It uses `Req` for HTTP transport and handles:

  - Bearer token authentication via `STRIPE_SECRET_KEY`
  - Pinned Stripe API version via `Stripe-Version` header
  - JSON request/response encoding
  - Error normalization into generated Stripe error types
  - Configurable base URL and extra Req options (the test transport seam)
  - Idempotency keys for POST requests (optional, via `:idempotency_key` opt)

  ## Configuration

      config :dhc, :stripe_secret_key, System.get_env("STRIPE_SECRET_KEY")
      config :dhc, :stripe_api_url, "https://api.stripe.com"
      config :dhc, :stripe_api_version, "2025-10-29.clover"

  The API version pins the Stripe API to a specific version, matching the
  Deno edge functions. Update it when upgrading, and re-run `mise run stripe-gen`.

  ## Testing

  Every Stripe HTTP call in the app goes through `request/1`, which merges
  `config :dhc, :stripe_req_options` into its Req options. `config/test.exs`
  sets `plug: {Req.Test, Dhc.Stripe}`, so tests stub Stripe in-process with
  `Req.Test.stub(Dhc.Stripe, plug)` (see `Dhc.StripeHTTPStub` for a
  method/path router). Stubs follow Req.Test ownership: they reach Tasks and
  other `$callers` descendants of the test process; anything else needs
  `Req.Test.allow/3`.

  ## Usage with generated operations

  Generated operations call this module via `@default_client`:

      Dhc.Stripe.Operations.get_subscriptions(%{}, client: Dhc.Stripe.Client)

  Or with a test client override:

      Dhc.Stripe.Operations.get_subscriptions(%{}, client: MyTestClient)
  """

  require Logger

  @closed_checkout_messages Enum.map(~w(complete expired), fn state ->
                              ~s(Only Checkout Sessions with a status in ["open"] can be expired. This Checkout Session has a status of `#{state}`.)
                            end)

  @doc """
  Performs an HTTP request to the Stripe API.

  Called by generated operation functions with a keyword list containing:
  - `:method` — HTTP method atom (`:get`, `:post`, `:put`, `:patch`, `:delete`)
  - `:url` — URL path (e.g. `"/v1/subscriptions"`)
  - `:body` — request body (map or nil)
  - `:query` — keyword list of query parameters
  - `:opts` — keyword list of options (may include `:client` override)

  Returns `{:ok, decoded_body}` on success or `{:error, term()}` on failure.
  """
  @spec request(keyword()) :: {:ok, map()} | {:error, term()}
  def request(opts) when is_map(opts), do: opts |> Map.to_list() |> request()

  def request(opts) do
    method = Keyword.get(opts, :method, :get)
    url = Keyword.get(opts, :url, "")
    body = Keyword.get(opts, :body)
    query = Keyword.get(opts, :query, [])

    stripe_key = stripe_secret_key()

    if is_nil(stripe_key) or stripe_key == "" do
      Logger.error("[stripe-client] STRIPE_SECRET_KEY not configured")
      {:error, :stripe_key_not_configured}
    else
      full_url = stripe_api_url() <> url <> query_string(query)

      headers =
        [
          {"authorization", "Bearer #{stripe_key}"},
          {"stripe-version", stripe_api_version()},
          {"content-type", "application/x-www-form-urlencoded"}
        ]
        |> maybe_add_idempotency_key(opts)

      req_opts =
        Keyword.merge(
          [decode_body: true, retry: false, connect_options: [timeout: 30_000]],
          Application.get_env(:dhc, :stripe_req_options, [])
        )

      req_opts =
        req_opts
        |> maybe_add_form_body(body, method)

      result =
        Req.request(
          [method: method, url: full_url, headers: headers] ++
            req_opts
        )

      handle_result(result, method, url)
    end
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body}}, _method, _url)
       when status in 200..299 do
    {:ok, body}
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body} = response}, method, url) do
    error = if is_map(body), do: Map.get(body, "error", %{}), else: %{}
    error = if is_map(error), do: error, else: %{}
    endpoint = safe_endpoint(url)
    request_id = safe_identifier(response.headers["request-id"] |> List.wrap() |> List.first())
    code = safe_identifier(error["code"])
    type = safe_identifier(error["type"])

    Logger.log(
      error_level(status, method, endpoint, error),
      "[stripe-client] Stripe API returned #{status} " <>
        "#{method} #{endpoint} code=#{code} type=#{type} request_id=#{request_id}",
      status: status,
      stripe_endpoint: endpoint,
      stripe_method: method,
      stripe_error_code: code,
      stripe_error_type: type,
      stripe_request_id: request_id
    )

    {:error, {:stripe_api, status, body}}
  end

  defp handle_result({:error, exception}, method, url) do
    Logger.error("[stripe-client] HTTP request failed #{method} #{safe_endpoint(url)}")
    {:error, {:http_error, exception}}
  end

  # Only Stripe's explicit terminal-state refusal is expected. The caller
  # still receives the error and retrieves the authoritative session; no
  # other 400, message variant, endpoint or error type is downgraded.
  defp error_level(400, :post, "/v1/checkout/sessions/:id/expire", %{
         "type" => "invalid_request_error",
         "message" => message
       })
       when message in @closed_checkout_messages,
       do: :warning

  defp error_level(_status, _method, _endpoint, _error), do: :error

  @endpoint_segments ~w(v1 customers subscriptions payment_intents setup_intents payment_methods invoices prices coupons promotion_codes refunds checkout sessions billing_portal create_preview cancel attach detach expire)

  defp safe_endpoint(url) do
    url
    |> String.split("?", parts: 2)
    |> hd()
    |> String.split("/", trim: true)
    |> Enum.map_join("/", fn segment ->
      if segment in @endpoint_segments, do: segment, else: ":id"
    end)
    |> then(&("/" <> &1))
  end

  defp safe_identifier(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-zA-Z0-9_]{1,128}\z/, value), do: value, else: "unknown"
  end

  defp safe_identifier(_value), do: "unknown"

  defp maybe_add_idempotency_key(headers, call_opts) do
    request_opts = Keyword.get(call_opts, :opts, [])

    case Keyword.get(request_opts, :idempotency_key) || Keyword.get(call_opts, :idempotency_key) do
      nil -> headers
      key -> [{"idempotency-key", key} | headers]
    end
  end

  defp maybe_add_form_body(opts, nil, _method), do: opts
  defp maybe_add_form_body(opts, body, :get) when body in [[], %{}], do: opts

  defp maybe_add_form_body(opts, body, _method) when is_map(body) or is_list(body) do
    Keyword.put(opts, :form, normalize_form_params(body))
  end

  defp maybe_add_form_body(opts, body, _method), do: Keyword.put(opts, :body, body)

  defp normalize_form_params(params) when is_map(params), do: Map.to_list(params)
  defp normalize_form_params(params) when is_list(params), do: params

  # Encoded here rather than through Req's `:params`, which keeps only the
  # last value of a repeated key and would collapse `lookup_keys[]=a&lookup_keys[]=b`.
  defp query_string(query) do
    case format_query(query) do
      [] -> ""
      pairs -> "?" <> URI.encode_query(pairs)
    end
  end

  # A list value becomes repeated `key[]=` pairs (a key already ending in
  # `[]` keeps it), `nil` values are skipped rather than sent as `key=`, and
  # nested maps are rejected: no generated list operation needs them, and
  # guessing an encoding would silently send the wrong filter.
  defp format_query(nil), do: []

  defp format_query(query) when is_list(query) do
    Enum.flat_map(query, fn
      {_key, nil} ->
        []

      {key, values} when is_list(values) ->
        encoded_key = stripe_array_key(key)
        for value <- values, not is_nil(value), do: {encoded_key, value}

      {key, value} when is_map(value) ->
        raise ArgumentError,
              "Dhc.Stripe.Client does not encode nested map query values " <>
                "(#{inspect(key)}: #{inspect(value)}); pass flat keys such as \"#{key}[gte]\""

      {key, value} ->
        [{to_string(key), value}]
    end)
  end

  defp stripe_array_key(key) do
    key = to_string(key)
    if String.ends_with?(key, "[]"), do: key, else: key <> "[]"
  end

  @spec stripe_api_url() :: String.t()
  defp stripe_api_url do
    Application.get_env(:dhc, :stripe_api_url, "https://api.stripe.com")
  end

  @spec stripe_api_version() :: String.t()
  defp stripe_api_version do
    Application.get_env(:dhc, :stripe_api_version, "2025-10-29.clover")
  end

  @spec stripe_secret_key() :: String.t() | nil
  defp stripe_secret_key do
    Application.get_env(:dhc, :stripe_secret_key)
  end
end
