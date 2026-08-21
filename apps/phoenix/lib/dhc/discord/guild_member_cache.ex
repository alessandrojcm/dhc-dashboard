defmodule Dhc.Discord.GuildMemberCache do
  @moduledoc false

  use GenServer

  @table __MODULE__

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def fetch(key, refresh?, loader, ttl_seconds)
      when is_function(loader, 0) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    now = System.monotonic_time(:second)

    if refresh? do
      load(key, loader, ttl_seconds, now)
    else
      case lookup(key, now) do
        {:hit, value, fetched_at} -> {:ok, value, fetched_at}
        :miss -> load(key, loader, ttl_seconds, now)
      end
    end
  end

  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call({:put, key, value, fetched_at, expires_at}, _from, state) do
    :ets.insert(@table, {key, value, fetched_at, expires_at})
    {:reply, :ok, state}
  end

  defp lookup(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, value, fetched_at, expires_at}] when expires_at > now ->
        {:hit, value, fetched_at}

      [_expired] ->
        :miss

      [] ->
        :miss
    end
  end

  defp load(key, loader, ttl_seconds, now) do
    case loader.() do
      {:ok, value} ->
        fetched_at = DateTime.utc_now() |> DateTime.truncate(:second)
        :ok = GenServer.call(__MODULE__, {:put, key, value, fetched_at, now + ttl_seconds})
        {:ok, value, fetched_at}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
