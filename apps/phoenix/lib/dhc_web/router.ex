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
    # Mirrors the corrected registration RLS policy
    # (`20250923100806_fix_workshops_rls.sql`) and the canonical
    # `Dhc.Workshops.coordinator_management_roles/0`. Deliberately excludes
    # `beginners_coordinator` — the historical registration visibility drift
    # (see the `Dhc.Workshops` moduledoc) must not be reproduced.
    plug DhcWeb.Plugs.RequireAuth, roles: Dhc.Workshops.coordinator_management_roles()
  end

  pipeline :settings_admin_api do
    plug DhcWeb.Plugs.RequireAuth, roles: ~w(president committee_coordinator admin)
  end

  # ALE-105 inventory category management. Mirrors the existing SvelteKit
  # `INVENTORY_ROLES` (`quartermaster`, `admin`, `president`). Reads of
  # categories are any authenticated member — the existing Svelte category
  # list view is member-readable; writes require the inventory write roles.
  pipeline :inventory_admin_api do
    plug DhcWeb.Plugs.RequireAuth, roles: ~w(quartermaster admin president)
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
    get "/workshops/:id/attendees", WorkshopsController, :attendees
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :settings_admin_api]

    get "/settings", SettingsController, :index
    patch "/settings/:key", SettingsController, :update
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :authenticated_api]

    get "/members/insurance-form", MembersController, :insurance_form
    get "/notifications", NotificationsController, :index
    get "/workshops", WorkshopsController, :list
    # ALE-105: any authenticated member may read equipment categories.
    get "/inventory/categories", InventoryCategoriesController, :index
    get "/inventory/categories/:id", InventoryCategoriesController, :show
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :inventory_admin_api]

    # ALE-105: write roles only.
    post "/inventory/categories", InventoryCategoriesController, :create
    patch "/inventory/categories/:id", InventoryCategoriesController, :update
    delete "/inventory/categories/:id", InventoryCategoriesController, :delete
  end
end
