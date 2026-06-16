# Migrate PostgREST reads to domain Phoenix APIs

Status: accepted

SvelteKit still contains browser/server Supabase PostgREST reads against tables and views, which leak storage shapes into UI code and depend on RLS for authorization. As Phoenix takes over application data access, we will replace these reads with OpenAPI-defined, domain-shaped Phoenix endpoints rather than generic table/view proxies; existing RLS policies are the source of truth for the initial Phoenix RBAC rules.

The first slice is the Waitlist domain: `GET /api/waitlist/status`, `GET /api/waitlist/entries`, and `GET /api/waitlist/analytics`. Waitlist admin reads mirror the stricter existing waitlist RLS roles (`admin`, `president`, `committee_coordinator`, `beginners_coordinator`, `coach`), use camelCase DTOs, cursor pagination with total count for entries, whitelisted sort fields, and preserve current search/status semantics where they are part of user-facing behavior.

This deliberately avoids a generic `settings`, `waitlist_management_view`, or table-shaped API. The trade-off is a small amount of frontend adaptation during migration, but the resulting contract matches the target architecture: SvelteKit consumes typed domain APIs, while Phoenix owns authorization and persistence details.
