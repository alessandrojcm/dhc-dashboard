# Service Domains

| Domain | Services | Purpose |
|--------|----------|---------|
| `members/` | MemberService, ProfileService, WaitlistService | Membership management |
| `workshops/` | WorkshopService, AttendanceService, RefundService, RegistrationService | Event coordination |
| `inventory/` | ItemService, ContainerService, CategoryService, HistoryService | Equipment tracking |
| `invitations/` | InvitationService | Member onboarding |
| `settings/` | SettingsService | App configuration |

## Roles (RBAC)

```typescript
WORKSHOP_ROLES: ['workshop_coordinator', 'president', 'admin']
SETTINGS_ROLES: ['president', 'committee_coordinator', 'admin']
INVENTORY_ROLES: ['quartermaster', 'admin', 'president']
```

Check with `authorize(locals, ROLES)` in API routes or `has_any_role()` in SQL.
