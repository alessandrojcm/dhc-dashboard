# LEGACY SVELTE SERVICE LAYER

Phoenix owns migrated domain operations. Do not add new Svelte service modules for
members, inventory, or workshops; call Phoenix through `@dhc/api-client`.

## REMAINING SERVICES

```
services/
├── shared/       # RLS, logging, common types, and test utilities
├── invitations/  # Temporary: invitation bulk deletion
└── settings/     # Temporary: settings reads and waitlist toggle
```

The remaining services are migration compatibility code. When their final callers
move to Phoenix, delete the service and any service-only tests rather than extending
the legacy layer.

## CURRENT CALLERS

- `InvitationService.bulkDelete()` is called by
  `src/routes/dashboard/beginners-workshop/admin.remote.ts`.
- `SettingsService` is called by the members and beginners-workshop server routes.
- `InsuranceFormLinkSchema` is still re-exported from the settings service module.

## RULES

- Prefer `@dhc/api-client` for all new server operations.
- Do not recreate deleted members, inventory, or workshop services.
- Keep `executeWithRLS()` around any database access that remains in this directory.
- Instantiate remaining services through their factory functions; do not create
  global instances.
