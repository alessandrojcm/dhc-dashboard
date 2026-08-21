defmodule Dhc.Discord.RestClientSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(options) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(options) do
    token = Keyword.fetch!(options, :token)

    children = [
      Nostrum.Api.RatelimiterGroup,
      {Nostrum.Api.Ratelimiter, {token, []}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
