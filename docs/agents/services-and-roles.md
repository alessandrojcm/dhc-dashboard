# Service Domains

| Domain | Services | Purpose |
|--------|----------|---------|
| `members/` | MemberService, ProfileService, WaitlistService | Membership management |
| `workshops/` | WorkshopService, AttendanceService, RefundService, RegistrationService | Event coordination |
| `inventory/` | ItemService, ContainerService, CategoryService, HistoryService | Equipment tracking |
| `invitations/` | InvitationService | Member onboarding |
| `settings/` | SettingsService | App configuration |

## Roles (RBAC)

Frontend role policy lives behind typed capabilities in
`apps/web/src/lib/server/authorization/` (GH-510). Feature code never imports
role sets; it asks `authorizationFor(session).can("inventory.manage")` /
`.require(...)`, or `authorize(locals, "workshops.manage")` when it only needs
the session back. Role → capability rules are the single table in
`capabilities.ts`; they mirror the Phoenix router pipelines, which remain the
authoritative enforcement (`has_any_role()` in SQL, plugs in Phoenix).
