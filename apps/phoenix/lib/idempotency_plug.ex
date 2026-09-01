defmodule IdempotencyPlug do
  @moduledoc """
  Idempotency-Key request handling vendored from `danschultzer/idempotency_plug`
  v0.2.2 (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT
  licensed.

  The original ETS store and migration generator are deliberately omitted. DHC
  uses the durable `IdempotencyPlug.EctoStore` instead.
  """

  @behaviour Plug

  alias IdempotencyPlug.RequestTracker
  alias Plug.Conn

  @type mfa_tuple :: {module(), atom()} | {module(), atom(), [term()]}

  @impl true
  def init(options) do
    options
    |> verify_tracker!()
    |> verify_with!()
    |> verify_mfa_tuple!(:idempotency_key, {__MODULE__, :idempotency_key})
    |> verify_mfa_tuple!(:request_payload, {__MODULE__, :request_payload})
    |> verify_mfa_tuple!(:hash, {__MODULE__, :sha256_hash})
    |> verify_cached_headers!()
  end

  @impl true
  def call(%{method: method} = conn, options) when method in ~w(POST PATCH) do
    case Conn.get_req_header(conn, "idempotency-key") do
      [key] -> handle_idempotent_request(conn, key, options)
      [_ | _] -> handle_error(conn, %IdempotencyPlug.MultipleHeadersError{}, options)
      [] -> handle_error(conn, %IdempotencyPlug.NoHeadersError{}, options)
    end
  end

  def call(conn, _options), do: conn

  @doc false
  @spec idempotency_key(Conn.t(), term()) :: term()
  def idempotency_key(_conn, key), do: key

  @doc false
  @spec request_payload(Conn.t()) :: [{binary(), term()}]
  def request_payload(conn), do: conn.params |> Map.to_list() |> Enum.sort()

  @doc false
  @spec sha256_hash(:idempotency_key | :request_payload, term()) :: binary()
  def sha256_hash(_type, value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16()
    |> String.downcase()
  end

  defp handle_idempotent_request(conn, key, options) do
    tracker = Keyword.fetch!(options, :tracker)
    request_id = hash_idempotency_key(conn, key, options)
    fingerprint = hash_request_payload(conn, options)

    case RequestTracker.track(tracker, request_id, fingerprint) do
      {:processing, _node_caller, _expires_at} ->
        handle_error(conn, %IdempotencyPlug.ConcurrentRequestError{}, options)

      {:mismatch, {:fingerprint, fingerprint}, _expires_at} ->
        handle_error(
          conn,
          %IdempotencyPlug.RequestPayloadFingerprintMismatchError{fingerprint: fingerprint},
          options
        )

      {:cache, {:halted, reason}, _expires_at} ->
        handle_error(conn, %IdempotencyPlug.HaltedResponseError{reason: reason}, options)

      {:cache, {:ok, response}, expires_at} ->
        conn
        |> put_response(response, options)
        |> put_expires_header(expires_at)
        |> Conn.halt()

      {:init, request_id, _expires_at} ->
        register_response_before_send(conn, request_id, options)

      {:error, error} ->
        raise "failed to track request, got: #{inspect(error)}"
    end
  end

  defp hash_idempotency_key(conn, key, options) do
    {module, function, arguments} = Keyword.fetch!(options, :idempotency_key)
    key = apply(module, function, [conn, {key, conn.path_info} | arguments])
    hash(:idempotency_key, key, options)
  end

  defp hash_request_payload(conn, options) do
    {module, function, arguments} = Keyword.fetch!(options, :request_payload)
    payload = apply(module, function, [conn | arguments])
    hash(:request_payload, payload, options)
  end

  defp hash(type, value, options) do
    {module, function, arguments} = Keyword.fetch!(options, :hash)
    apply(module, function, [type, value | arguments])
  end

  defp register_response_before_send(conn, request_id, options) do
    tracker = Keyword.fetch!(options, :tracker)

    Conn.register_before_send(conn, fn conn ->
      case RequestTracker.put_response(tracker, request_id, response_from(conn)) do
        {:ok, expires_at} -> put_expires_header(conn, expires_at)
        {:error, error} -> raise "failed to put response in cache store, got: #{inspect(error)}"
      end
    end)
  end

  defp response_from(conn), do: Map.take(conn, [:resp_body, :resp_headers, :status])

  defp put_response(conn, %{resp_body: body, resp_headers: headers, status: status}, options) do
    headers =
      Enum.reduce(Keyword.fetch!(options, :cached_headers), headers, fn {key, value}, headers ->
        List.keystore(headers, key, 0, {key, value})
      end)

    Conn.resp(%{conn | resp_headers: headers}, status, body)
  end

  defp put_expires_header(conn, expires_at) do
    Conn.put_resp_header(conn, "expires", imf_fixdate(expires_at))
  end

  defp imf_fixdate(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %X GMT")
  end

  defp handle_error(conn, error, options) do
    case Keyword.fetch!(options, :with) do
      :exception -> raise error
      {module, function, arguments} -> apply(module, function, [conn, error | arguments])
    end
  end

  defp verify_tracker!(options) do
    case Keyword.get(options, :tracker) do
      tracker when is_pid(tracker) or (is_atom(tracker) and not is_nil(tracker)) ->
        options

      other ->
        raise ArgumentError, "option :tracker must be a GenServer server, got: #{inspect(other)}"
    end
  end

  defp verify_with!(options) do
    with_option =
      case Keyword.get(options, :with, :exception) do
        :exception ->
          :exception

        {module, function} ->
          {module, function, []}

        {module, function, arguments} ->
          {module, function, arguments}

        other ->
          raise ArgumentError,
                "option :with must be :exception or an MFA tuple, got: #{inspect(other)}"
      end

    Keyword.put(options, :with, with_option)
  end

  defp verify_mfa_tuple!(options, key, default) do
    value =
      case Keyword.get(options, key, default) do
        {module, function} ->
          {module, function, []}

        {module, function, arguments} ->
          {module, function, arguments}

        other ->
          raise ArgumentError,
                "option #{inspect(key)} must be an MFA tuple, got: #{inspect(other)}"
      end

    Keyword.put(options, key, value)
  end

  defp verify_cached_headers!(options) do
    headers = Keyword.get(options, :cached_headers, [])

    unless is_list(headers) and
             Enum.all?(
               headers,
               &match?({key, value} when is_binary(key) and is_binary(value), &1)
             ) do
      raise ArgumentError, "option :cached_headers must be a list of {name, value} tuples"
    end

    Keyword.put(options, :cached_headers, headers)
  end
end
