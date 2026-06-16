defmodule DhcWeb.Router do
  use DhcWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :invitation_admin_api do
    plug DhcWeb.Plugs.RequireAuth, roles: ~w(president admin committee_coordinator)
  end

  pipeline :waitlist_admin_api do
    plug DhcWeb.Plugs.RequireAuth,
      roles: ~w(admin president committee_coordinator beginners_coordinator coach)
  end

  scope "/api", DhcWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/waitlist/status", WaitlistController, :index
    post "/webhooks/stripe", StripeWebhooksController, :create
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :invitation_admin_api]

    post "/invitations", InvitationsController, :create
    post "/invitations/resend", InvitationsController, :resend
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :waitlist_admin_api]

    get "/waitlist/analytics", WaitlistController, :analytics
  end
end
