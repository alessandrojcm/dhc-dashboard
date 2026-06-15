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
- A custom Mix task (`mix gen.controllers`) reads the spec and generates Phoenix boilerplate: controllers, JSON renderers, router entries, and ExUnit contract tests.
- `openapi-typescript` generates the TypeScript client from the same spec.
- The TypeScript client is published as a workspace package (`packages/api-client`) in the monorepo.
- The spec grows incrementally per domain — not written globally upfront.

### What the Generator Emits

| Component | Generated? | Notes |
|-----------|------------|-------|
| Controller actions | **Yes** | Full wiring: Ecto.Changeset validation → context call → `render/3`. Action names follow REST conventions (`index`, `show`, `create`, `update`, `delete`). Non-REST operations map verbatim (e.g., `renew/2`). |
| JSON renderer modules (`*JSON`) | **Yes** | Pattern-match on `%Dhc.<Context>.<Struct>{}` and emit the exact fields declared in the OpenAPI response schema. |
| Router entries | **Yes** | Printed to console; developer pastes into `router.ex`. |
| Ecto schemas & migrations | **No** | Hand-written. The DB model is intentionally decoupled from the API contract. |
| Context modules & functions | **No** | Hand-written business logic. Controllers call `Dhc.<Tag>.<conventional_name>/N` (e.g., `Dhc.Members.list_members/0`). |
| ExUnit controller tests | **Yes** | Minimal contract tests: assert correct status codes (200, 201, 422) and response body shape. Business logic tests are written separately. |

### Validation Strategy

Request validation is **explicit and generated**, not runtime-magical. The generator emits an Ecto.Changeset in each controller action that casts and validates params according to the OpenAPI spec's request body schema. If the spec changes, re-run `mix gen.controllers` to update the validation code. This keeps the OpenAPI spec as the contract source of truth while avoiding the "spec-driven config" anti-pattern — there is no invisible plug that auto-validates from the YAML at runtime.

### File Overwrite Behaviour

The generator skips existing files by default. Re-running it only creates new files for newly-added endpoints. Use `--force` to overwrite a specific file. This prevents accidental loss of hand-written context calls.

### Auth

The generator makes **no assumptions about authentication**. A `DhcWeb.Plugs.RequireAuth` (or equivalent) must be wired into the router pipeline manually before any generated controller is exposed.

### Tooling Choice

The generator is a **pure Elixir Mix task** using EEx templates. We evaluated Yellicode, `@fresha/openapi-codegen-server-elixir`, and `apical`, but a custom Mix task is simpler: no new toolchain for Elixir developers, EEx is more ergonomic than Mustache for logic-heavy generation, and the generator lives in the repo as plain Elixir code.

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
