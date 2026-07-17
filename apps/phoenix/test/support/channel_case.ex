defmodule DhcWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channel/socket integration tests.

  Mirrors `DhcWeb.ConnCase` and `Dhc.DataCase`: it starts the SQL sandbox so
  channel tests that touch the database (e.g. the Notifications context) stay
  isolated, imports `Phoenix.ChannelTest` for `connect/3`, `socket/1-3`,
  `subscribe_and_join/4`, `join/3`, `push/3`, `assert_push/3`, and
  `assert_broadcast/3`, and sets `@endpoint` so the helpers resolve the
  configured endpoint and its pubsub server.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The endpoint under test; required by Phoenix.ChannelTest helpers.
      @endpoint DhcWeb.Endpoint

      use DhcWeb, :verified_routes

      import Phoenix.ChannelTest
      import DhcWeb.ChannelCase
    end
  end

  setup tags do
    Dhc.DataCase.setup_sandbox(tags)
    :ok
  end
end
