# Handoff — DHC-dashboard Local-first PWA: Phase 2 (PWA shell)

## Context

Same programme as `phase-1-phoenix-versioning-idempotency.md` (in this directory) — read that first for the overall architecture and repo layout. This is the PWA shell phase, independent of the local-store/outbox work and can proceed in parallel.

**Agreed architecture:** SvelteKit-native service worker (`apps/web/src/service-worker.ts`) using `$service-worker` (`build`, `files`, `version` exports). Precache + cache-first for build/static assets only, versioned cache names, purge old caches on activate. **No `vite-plugin-pwa`.**

Deliberate non-caching (important):
- No API routes (including `/api/auth/session`).
- No personalised SSR HTML (shared-browser-profile leak risk). Authenticated state lives in the cookie + client-side local data, so caching the app-shell HTML is fine.
- Offline indicator driven by **actual query/mutation failures**, not just `navigator.onLine`.

## Tasks

1. `apps/web/static/manifest.webmanifest` (name, short_name "DHC", start_url/scope `/`, display standalone, 192/512 icons) + `<link rel="manifest">` in `src/app.html`.
2. `src/service-worker.ts`: install → `caches.open(\`dhc-${version}\`)` + `addAll([...build, ...files])`; activate → delete stale `dhc-*` caches; fetch → cache-first only for same-origin GETs matching known assets, otherwise pass through.
3. Offline banner/toast component wired to a small connectivity store fed by query/mutation failure events plus `online`/`offline` events.
4. Verify: cold start online, warm start offline (app shell renders), version upgrade (old cache purged).
5. Icons may need to be produced — check `apps/web/static` for existing assets before generating.

## Conventions

- Frontend lint via `pnpm lint` (oxlint), format via Oxfmt from `apps/web`; `pnpm check` for svelte-check. Run from `apps/web`.
- Test setup: vitest unit + Playwright e2e (`e2e/` has its own AGENTS.md).
- The svelte MCP tools (`tools.svelte["get-documentation"]`) are available for SvelteKit service-worker docs.
- Svelte/SvelteKit docs lookup should go through the `svelte` MCP tool rather than web search.

## Suggested skills

- `implement` — executing this phase
- `show-me` — if the user wants a diagram of SW lifecycle
- `ui-ux-pro-max` — only if the offline indicator needs design work

## Open questions

- Whether the offline banner should appear app-wide or per-route (e.g. only on dashboard routes).
- iOS-specific manifest additions (apple-touch-icon etc.) — decide how far to go in v1.