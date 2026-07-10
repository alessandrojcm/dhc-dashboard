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
    get "/options", MembersController, :options
    get "/waitlist/status", WaitlistController, :index
    post "/waitlist/entries", WaitlistController, :create
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
    get "/waitlist/entries/:id", WaitlistController, :show
    patch "/waitlist/entries/:id", WaitlistController, :update
    get "/waitlist/entries/:id/guardian", WaitlistController, :guardian
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
    get "/members/:memberId", MembersController, :show
    patch "/members/:memberId", MembersController, :update
    post "/members/:memberId/membership/pause", MembershipController, :pause
    post "/members/:memberId/membership/resume", MembershipController, :resume
    get "/notifications", NotificationsController, :index
    get "/workshops", WorkshopsController, :list
    # ALE-105: any authenticated member may read equipment categories.
    get "/inventory/categories", InventoryCategoriesController, :index
    get "/inventory/categories/:id", InventoryCategoriesController, :show
    # ALE-106: any authenticated member may read inventory containers.
    get "/inventory/containers", InventoryContainersController, :index
    get "/inventory/containers/:id", InventoryContainersController, :show
    # ALE-107: any authenticated member may read inventory items + history.
    get "/inventory/items", InventoryItemsController, :index
    get "/inventory/items/:id", InventoryItemsController, :show
    get "/inventory/items/:id/history", InventoryItemsController, :history
    # ALE-108: any authenticated member may read the global inventory activity feed.
    get "/inventory/history", InventoryHistoryController, :index
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :inventory_admin_api]

    # ALE-105: write roles only.
    post "/inventory/categories", InventoryCategoriesController, :create
    patch "/inventory/categories/:id", InventoryCategoriesController, :update
    delete "/inventory/categories/:id", InventoryCategoriesController, :delete
    # ALE-106: write roles only.
    post "/inventory/containers", InventoryContainersController, :create
    patch "/inventory/containers/:id", InventoryContainersController, :update
    delete "/inventory/containers/:id", InventoryContainersController, :delete
    # ALE-107: write roles only.
    post "/inventory/items", InventoryItemsController, :create
    patch "/inventory/items/:id", InventoryItemsController, :update
    delete "/inventory/items/:id", InventoryItemsController, :delete
    # ALE-108: dedicated movement/maintenance command endpoints, write roles only.
    post "/inventory/items/:id/move", InventoryItemsController, :move
    post "/inventory/items/:id/maintenance", InventoryItemsController, :maintenance
  end
end
