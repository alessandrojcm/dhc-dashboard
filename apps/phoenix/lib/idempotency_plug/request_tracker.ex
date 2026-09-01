defmodule IdempotencyPlug.RequestTracker do
  @moduledoc """
  Request tracker vendored from `danschultzer/idempotency_plug` v0.2.2
  (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT licensed.

  It tracks in-flight requests, stores completed responses for 24 hours, and
  periodically prunes expired entries through the configured durable store.
  """

  use GenServer

  @cache_ttl :timer.hours(24)
  @prune_interval :timer.seconds(60)

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    options = Keyword.merge([cache_ttl: @cache_ttl, prune: @prune_interval], options)
    GenServer.start_link(__MODULE__, normalize_store(options), name: name)
  end

  @spec track(GenServer.server(), binary(), binary()) :: tuple()
  def track(server, request_id, fingerprint),
    do: GenServer.call(server, {:track, request_id, fingerprint})

  @spec put_response(GenServer.server(), binary(), term()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def put_response(server, request_id, response),
    do: GenServer.call(server, {:put_response, request_id, response})

  @impl true
  def init(options) do
    {store, store_options} = fetch_store(options)

    case store.setup(store_options) do
      :ok ->
        Process.send_after(self(), :prune, Keyword.fetch!(options, :prune))
        {:ok, %{monitored: [], options: options}}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:track, request_id, fingerprint}, {caller, _tag}, state) do
    {store, store_options} = fetch_store(state.options)

    case store.lookup(request_id, store_options) do
      :not_found ->
        insert_request(state, store, store_options, request_id, fingerprint, caller)

      {{:processing, node_caller}, ^fingerprint, expires_at} ->
        {:reply, {:processing, node_caller, expires_at}, state}

      {{:halted, reason}, ^fingerprint, expires_at} ->
        {:reply, {:cache, {:halted, reason}, expires_at}, state}

      {{:ok, response}, ^fingerprint, expires_at} ->
        {:reply, {:cache, {:ok, response}, expires_at}, state}

      {_data, stored_fingerprint, expires_at} ->
        {:reply, {:mismatch, {:fingerprint, stored_fingerprint}, expires_at}, state}
    end
  end

  @impl true
  def handle_call({:put_response, request_id, response}, _from, state) do
    {store, store_options} = fetch_store(state.options)
    {_finished, state} = pop_monitored(state, &(elem(&1, 0) == request_id))
    expires_at = expires_at(state.options)

    case store.update(request_id, {:ok, response}, expires_at, store_options) do
      :ok -> {:reply, {:ok, expires_at}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _reference, :process, pid, reason}, state) do
    {store, store_options} = fetch_store(state.options)
    {finished, state} = pop_monitored(state, &(elem(&1, 1) == pid))
    expires_at = expires_at(state.options)

    Enum.each(finished, fn {request_id, _pid, _reference} ->
      store.update(request_id, {:halted, reason}, expires_at, store_options)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:prune, state) do
    {store, store_options} = fetch_store(state.options)
    :ok = store.prune(store_options)
    Process.send_after(self(), :prune, Keyword.fetch!(state.options, :prune))
    {:noreply, state}
  end

  defp normalize_store(options) do
    store =
      case options[:store] do
        {module, store_options} ->
          {module, store_options}

        module when is_atom(module) and not is_nil(module) ->
          {module, []}

        nil ->
          raise ArgumentError, "option :store is required"
      end

    Keyword.put(options, :store, store)
  end

  defp insert_request(state, store, store_options, request_id, fingerprint, caller) do
    expires_at = expires_at(state.options)

    case store.insert(
           request_id,
           {:processing, {Node.self(), caller}},
           fingerprint,
           expires_at,
           store_options
         ) do
      :ok ->
        {:reply, {:init, request_id, expires_at}, put_monitored(state, request_id, caller)}

      {:error, _reason} ->
        track_existing(state, store, store_options, request_id, fingerprint)
    end
  end

  defp track_existing(state, store, store_options, request_id, fingerprint) do
    case store.lookup(request_id, store_options) do
      {{:processing, node_caller}, ^fingerprint, expires_at} ->
        {:reply, {:processing, node_caller, expires_at}, state}

      {{:halted, reason}, ^fingerprint, expires_at} ->
        {:reply, {:cache, {:halted, reason}, expires_at}, state}

      {{:ok, response}, ^fingerprint, expires_at} ->
        {:reply, {:cache, {:ok, response}, expires_at}, state}

      {_data, stored_fingerprint, expires_at} ->
        {:reply, {:mismatch, {:fingerprint, stored_fingerprint}, expires_at}, state}

      :not_found ->
        {:reply, {:error, :request_disappeared}, state}
    end
  end

  defp fetch_store(options) do
    {store, store_options} = Keyword.fetch!(options, :store)
    {store, Keyword.merge(store_options, Keyword.take(options, [:cache_ttl]))}
  end

  defp put_monitored(state, request_id, caller) do
    reference = Process.monitor(caller)
    %{state | monitored: [{request_id, caller, reference} | state.monitored]}
  end

  defp pop_monitored(state, predicate) do
    {finished, monitored} = Enum.split_with(state.monitored, predicate)
    Enum.each(finished, fn {_request_id, _pid, reference} -> Process.demonitor(reference) end)
    {finished, %{state | monitored: monitored}}
  end

  defp expires_at(options),
    do: DateTime.add(DateTime.utc_now(), Keyword.fetch!(options, :cache_ttl), :millisecond)
end
