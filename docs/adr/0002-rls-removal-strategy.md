# ADR 0002: Row-Level Security Removal Strategy

**Status:** Accepted  
**Date:** 2026-05-12  
**Deciders:** @alessandrojcm  
**Tags:** rls, authorization, database, postgrest

## Context

The current application enforces authorization at two levels:

1. **Phoenix/Elixir application code** — after migration, the Ecto service contexts enforce role checks
2. **Postgres Row-Level Security (RLS)** — policies using `has_any_role()` are defined on every table

This dual enforcement was necessary when PostgREST exposed the database directly to the client (SvelteKit connected with anon key). After migrating all business logic to Phoenix, Phoenix connects to Postgres with full admin credentials and PostgREST will be disabled. RLS becomes redundant — the application code is the sole gatekeeper.

Maintaining RLS has costs: policies are written in SQL separate from the application logic, must be kept in sync with authorization rules, and add cognitive load when reasoning about data access.

## Decision

- **No new RLS policies** will be added going forward.
- **Existing RLS policies remain active** while PostgREST is still in the critical path (i.e. SvelteKit might still query Supabase directly for some reads during the transition).
- **When PostgREST is fully disabled**, all RLS policies are removed from the database in a clean-up migration.
- Phoenix enforces authorization exclusively via plug pipelines and Ecto context guard functions.

## Consequences

- One authorization system to reason about — Phoenix application code.
- No risk of diverging RLS policies vs. application logic.
- Fresh environments will still create RLS policies in the Ecto baseline (they are part of the current schema snapshot). They become dead code once PostgREST is disabled and are removed in a follow-up migration.
- During the transition period, a table not yet proxied through Phoenix could theoretically be accessed directly via PostgREST with RLS as the only protection. Each domain's cut-over must ensure Phoenix serves all reads/writes for that table before PostgREST access is removed.

## Alternatives Considered

- **Keep RLS as defense-in-depth.** Rejected because maintaining duplicate authorization rules in two languages (SQL and Elixir) adds ongoing cognitive load for marginal security benefit when Phoenix is the only database client.
- **Generate RLS from Elixir authorization rules.** Interesting idea but requires a bespoke code generator with no clear tooling path. The cost of building and maintaining the generator exceeds the benefit over a single-system approach.
