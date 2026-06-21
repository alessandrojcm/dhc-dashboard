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

  pipeline :members_admin_api do
    plug DhcWeb.Plugs.RequireAuth,
      roles:
        ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)
  end

  pipeline :workshop_coordinator_api do
    plug DhcWeb.Plugs.RequireAuth, roles: Dhc.Workshops.coordinator_management_roles()
  end

  pipeline :authenticated_api do
    plug DhcWeb.Plugs.RequireAuth
  end

  scope "/api", DhcWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/waitlist/status", WaitlistController, :index
    post "/webhooks/stripe", StripeWebhooksController, :create
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :invitation_admin_api]

    get "/invitations", InvitationsController, :list
    post "/invitations", InvitationsController, :create
    post "/invitations/resend", InvitationsController, :resend
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :waitlist_admin_api]

    get "/waitlist/analytics", WaitlistController, :analytics
    get "/waitlist/entries", WaitlistController, :entries
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :members_admin_api]

    get "/members", MembersController, :index
    get "/members/analytics", MembersController, :analytics
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :workshop_coordinator_api]

    get "/workshops/calendar", WorkshopsController, :calendar
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :authenticated_api]

    get "/members/insurance-form", MembersController, :insurance_form
    get "/notifications", NotificationsController, :index
  end
end
