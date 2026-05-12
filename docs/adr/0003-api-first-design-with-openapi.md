# ADR 0003: API-First Design with OpenAPI Spec

**Status:** Accepted  
**Date:** 2026-05-12  
**Deciders:** @alessandrojcm  
**Tags:** api, openapi, code-generation, typescript

## Context

During Phase 1 of the migration, SvelteKit talks to Phoenix over HTTP. The API surface needs to be:

1. **Type-safe** across the Elixir/TypeScript boundary so coding agents and developers get compile-time feedback
2. **Documented** for future integrations (automations, scripts, third-party consumers)
3. **Maintainable** as more domains migrate from SvelteKit services to Phoenix controllers

The Elixir ecosystem supports both code-first (annotate controllers → generate OpenAPI spec) and spec-first (write OpenAPI → generate controllers).

## Decision

**Spec-first (B3)** : The OpenAPI YAML spec is the authoritative contract. Both Phoenix controllers and the TypeScript client library are generated from it.

- The spec lives at `priv/api/openapi.yaml` in the Phoenix app.
- A custom Mix task reads the spec and emits Phoenix controller stubs (module + function signatures with `raise "not implemented"`).
- `openapi-typescript` generates the TypeScript client from the same spec.
- The TypeScript client is published as a workspace package (`packages/api-client`) in the monorepo.
- Implementation is filled in manually per endpoint; `open_api_spex` can validate responses against the spec at test time.
- The spec grows incrementally per domain — not written globally upfront.

## Consequences

- Single source of truth for the API contract.
- SvelteKit gets typed fetches. Refactoring an endpoint's shape changes the spec → regenerated client → TypeScript compile errors in the frontend.
- Future integrations (scripts, cron jobs, admin tools) consume the same generated client.
- The custom Mix task generator is a one-time investment (~100 lines of Elixir).
- During the transition, Phoenix and PostgREST both serve API responses. Their shapes must be similar enough for the frontend to handle both without branching. Once a domain is migrated, PostgREST access for that domain is removed.

## Alternatives Considered

- **Code-first (annotate Phoenix → generate OpenAPI).** Standard Elixir tooling, well-trodden path. Rejected because the spec should be authorative, not a byproduct.
- **Ash Framework with `ash_json_api`.** Automatically generates JSON:API endpoints from Ash resource definitions. Rejected because adopting Ash is a heavy framework dependency on top of already adding Phoenix + Ecto.
- **Ad-hoc JSON API without spec.** Rejected because we explicitly need type safety across the stack and documented endpoints for future integrations.
