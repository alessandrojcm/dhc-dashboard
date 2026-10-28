defmodule Dhc.Discord.RatelimiterStub do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    :ok = Nostrum.Api.RatelimiterGroup.join(self())
    {:ok, options}
  end

  @impl true
  def handle_call({:queue, request}, _from, options) do
    send(options[:owner], {:discord_request, request})
    {:reply, options[:respond].(request), options}
  end
end
