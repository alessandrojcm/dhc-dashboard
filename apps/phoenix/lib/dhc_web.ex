defmodule DhcWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use DhcWeb, :controller
      use DhcWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn
    end
  end

  # NOTE: `verified_routes/0` is deliberately NOT injected into `controller/0`.
  # Injecting `use Phoenix.VerifiedRoutes, router: DhcWeb.Router, endpoint: DhcWeb.Endpoint`
  # into every controller creates a compile-time edge controller → router →
  # controller (and controller → endpoint → router), which forces a full
  # `dhc_web` recompile whenever any one controller changes. Call this from
  # `html/0` / liveview code only, where `~p` is actually used. No controller
  # here uses `~p` (this is a JSON API), so controllers get nothing.
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: DhcWeb.Endpoint,
        router: DhcWeb.Router,
        statics: DhcWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
