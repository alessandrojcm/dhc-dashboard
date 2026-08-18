defmodule DhcWeb.Router do
  use DhcWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :invitation_admin_api do
    plug DhcWeb.Plugs.RequireSession, roles: ~w(president admin committee_coordinator)
  end

  pipeline :waitlist_admin_api do
    plug DhcWeb.Plugs.RequireSession,
      roles: ~w(admin president committee_coordinator beginners_coordinator coach)
  end

  pipeline :members_admin_api do
    plug DhcWeb.Plugs.RequireSession,
      roles:
        ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)
  end

  pipeline :workshop_coordinator_api do
    # Mirrors the corrected registration RLS policy
    # (`20250923100806_fix_workshops_rls.sql`) and the canonical
    # `Dhc.Workshops.coordinator_management_roles/0`. Deliberately excludes
    # `beginners_coordinator` — the historical registration visibility drift
    # (see the `Dhc.Workshops` moduledoc) must not be reproduced.
    plug DhcWeb.Plugs.RequireSession, roles: Dhc.Workshops.coordinator_management_roles()
  end

  pipeline :settings_admin_api do
    plug DhcWeb.Plugs.RequireSession, roles: ~w(president committee_coordinator admin)
  end

  pipeline :discord_doctor_admin_api do
    plug DhcWeb.Plugs.RequireSession, roles: ~w(admin president committee_coordinator)
  end

  # ALE-105 inventory category management. Mirrors the existing SvelteKit
  # `INVENTORY_ROLES` (`quartermaster`, `admin`, `president`). Reads of
  # categories are any authenticated member — the existing Svelte category
  # list view is member-readable; writes require the inventory write roles.
  pipeline :inventory_admin_api do
    plug DhcWeb.Plugs.RequireSession, roles: ~w(quartermaster admin president)
  end

  pipeline :authenticated_api do
    plug DhcWeb.Plugs.RequireSession
  end

  pipeline :authenticated_session_api do
    plug DhcWeb.Plugs.RequireSession
  end

  # ALE-165 — rate-limited, non-enumerating magic-link request. Public.
  # The plug short-circuits over-the-limit requests with the same 200 body
  # the controller returns for a known/unknown address.
  pipeline :magic_link_request_api do
    plug :accepts, ["json"]
    plug DhcWeb.Plugs.MagicLinkRateLimit
  end

  pipeline :discord_oauth_api do
    plug :fetch_session
  end

  if Application.compile_env(:dhc, :e2e_harness, false) do
    scope "/api/e2e", DhcWeb do
      pipe_through :api

      post "/reset", E2EHarnessController, :reset
      post "/seed/:scenario", E2EHarnessController, :seed
      post "/login", E2EHarnessController, :login
      post "/audit/invitation-acceptance/:id", E2EHarnessController, :invitation_acceptance_audit

      post "/onboarding/interrupt-next-finalization",
           E2EHarnessController,
           :interrupt_next_finalization

      post "/probes/onboarding-isolation", E2EHarnessController, :start_onboarding_isolation_probe

      get "/assertions/invitation-acceptance/:id",
          E2EHarnessController,
          :invitation_acceptance_assertion

      post "/onboarding/clear-finalization-interruption",
           E2EHarnessController,
           :clear_finalization_interruption

      patch "/fixtures/:type/:id", E2EHarnessController, :update_fixture
      post "/fixtures/:type/:id", E2EHarnessController, :delete_fixture
    end
  end

  scope "/api", DhcWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/onboarding/acceptance", OnboardingController, :show_acceptance
    post "/onboarding/acceptance", OnboardingController, :start_acceptance
    post "/onboarding/acceptance/continue", OnboardingController, :continue_acceptance
    post "/onboarding/acceptance/payment", OnboardingController, :submit_payment
    post "/onboarding/acceptance/retry", OnboardingController, :retry_acceptance
    post "/onboarding/acceptance/discord/cancel", OnboardingController, :cancel_discord

    get "/onboarding/invitation-acceptance",
        OnboardingController,
        :show_invitation_acceptance

    post "/onboarding/invitation-acceptance/verify",
         OnboardingController,
         :verify_invitation_acceptance

    post "/onboarding/invitation-acceptance/continue", OnboardingController, :continue_acceptance
    post "/onboarding/invitation-acceptance/payment", OnboardingController, :submit_payment
    post "/onboarding/invitation-acceptance/retry", OnboardingController, :retry_acceptance

    post "/onboarding/invitation-acceptance/discord/cancel",
         OnboardingController,
         :cancel_discord

    get "/options", MembersController, :options
    get "/invitations/:id", InvitationsController, :show
    get "/invitations/:id/pricing", InvitationsController, :pricing
    post "/invitations/:id/verify", InvitationsController, :verify
    post "/invitations/:id/accept", InvitationsController, :accept
    get "/waitlist/status", WaitlistController, :index
    post "/waitlist/entries", WaitlistController, :create
    post "/webhooks/stripe", StripeWebhooksController, :create
    get "/workshops/:id/external-registration", WorkshopsController, :external_registration_gate

    post "/workshops/:id/external-registration/checkout-session",
         WorkshopsController,
         :create_external_checkout_session

    post "/workshops/:id/external-registration/complete",
         WorkshopsController,
         :complete_external_registration
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :discord_oauth_api]

    get "/onboarding/invitation-acceptance/discord", OnboardingController, :start_discord
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :invitation_admin_api]

    get "/invitations", InvitationsController, :list
    post "/invitations", InvitationsController, :create
    delete "/invitations", InvitationsController, :delete
    post "/invitations/resend", InvitationsController, :resend
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :waitlist_admin_api]

    get "/waitlist/analytics", WaitlistController, :analytics
    patch "/waitlist/status", WaitlistController, :update_status
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
    pipe_through [:api, :discord_doctor_admin_api]

    get "/discord-doctor/report", DiscordDoctorController, :report
    post "/discord-doctor/kick", DiscordDoctorController, :kick
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :workshop_coordinator_api]

    post "/workshops", WorkshopsController, :create
    get "/workshops/calendar", WorkshopsController, :calendar
    get "/workshops/:id", WorkshopsController, :show
    patch "/workshops/:id", WorkshopsController, :update
    delete "/workshops/:id", WorkshopsController, :delete
    post "/workshops/:id/publish", WorkshopsController, :publish
    post "/workshops/:id/cancel", WorkshopsController, :cancel
    get "/workshops/:id/attendees", WorkshopsController, :attendees
    get "/workshops/:id/refunds", WorkshopsController, :refunds
    patch "/workshops/:id/attendance", WorkshopsController, :update_attendance

    post "/workshops/:id/registrations/:registration_id/refund",
         WorkshopsController,
         :refund_registration
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :settings_admin_api]

    get "/settings", SettingsController, :index
    patch "/settings/:key", SettingsController, :update
  end

  scope "/api", DhcWeb do
    pipe_through [:api, :authenticated_api]

    get "/members/insurance-form", MembersController, :insurance_form
    get "/members/me", MembersController, :me
    get "/members/:memberId", MembersController, :show
    patch "/members/:memberId", MembersController, :update
    post "/members/:memberId/membership/pause", MembershipController, :pause
    post "/members/:memberId/membership/resume", MembershipController, :resume
    post "/members/:memberId/billing-portal", MembershipController, :billing_portal
    get "/notifications", NotificationsController, :index
    post "/notifications/read-all", NotificationsController, :mark_all_read
    patch "/notifications/:id/read", NotificationsController, :mark_read
    get "/workshops", WorkshopsController, :list
    post "/workshops/:id/interest", WorkshopsController, :toggle_interest

    post "/workshops/:id/registration/payment-intent",
         WorkshopsController,
         :create_registration_payment_intent

    post "/workshops/:id/registration/complete", WorkshopsController, :complete_registration
    delete "/workshops/:id/registration", WorkshopsController, :cancel_registration
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
    get "/inventory/stats", InventoryDashboardController, :stats
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

  # Phoenix-session auth API. Lives under /api/auth/* and is the first
  # Phoenix-owned authentication path.
  scope "/api/auth", DhcWeb do
    # Magic-link request — public, rate-limited, non-enumerating.
    pipe_through :magic_link_request_api
    post "/magic-link", AuthSessionController, :request_magic_link
  end

  scope "/api/auth", DhcWeb do
    pipe_through :api

    # Magic-link verify — public (the token is the credential). Sets the
    # signed _dhc_session cookie on success.
    post "/magic-link/verify", AuthSessionController, :verify_magic_link
  end

  scope "/api/auth", DhcWeb do
    pipe_through :discord_oauth_api

    get "/discord", AuthSessionController, :request_discord
    get "/discord/callback", AuthSessionController, :discord_callback
  end

  scope "/api/auth", DhcWeb do
    pipe_through [:api, :discord_oauth_api, :authenticated_session_api]

    get "/discord/link", AuthSessionController, :request_discord_link
  end

  scope "/api/auth", DhcWeb do
    pipe_through [:api, :authenticated_session_api]

    # Session projection — requires a valid, active session.
    get "/session", AuthSessionController, :show_session
    # Sign out the current device — revokes the one session token.
    delete "/session", AuthSessionController, :delete_session
    # ALE-164 — exchange the session cookie for a short-lived JS-readable
    # socket token (the browser passes it via the Phoenix JS `authToken`
    # subprotocol; the HTTP-only cookie cannot be read by JS).
    get "/socket-token", AuthSessionController, :socket_token
  end
end
