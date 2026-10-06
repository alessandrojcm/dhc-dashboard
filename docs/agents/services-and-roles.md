# Service Domains

| Domain | Services | Purpose |
|--------|----------|---------|
| `members/` | MemberService, ProfileService, WaitlistService | Membership management |
| `workshops/` | WorkshopService, AttendanceService, RefundService, RegistrationService | Event coordination |
| `inventory/` | ItemService, ContainerService, CategoryService, HistoryService | Equipment tracking |
| `invitations/` | InvitationService | Member onboarding |
| `settings/` | SettingsService | App configuration |

## Roles (RBAC)

Role → capability rules are the single table in
`apps/phoenix/lib/dhc/auth/capabilities.ex` (ALE-344); Phoenix router
pipelines require a capability and the session projection carries the
capabilities a session holds. The frontend boundary
`apps/web/src/lib/server/authorization/` (GH-510) reads those capabilities and
adds only the owner rule and navigation. Feature code never reads roles; it
asks `authorizationFor(session).can("inventory.manage")` / `.require(...)`, or
`authorize(locals, "workshops.manage")` when it only needs the session back.
