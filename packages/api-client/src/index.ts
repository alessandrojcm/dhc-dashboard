// @dhc/api-client - Generated TypeScript SDK for DHC Dashboard API
//
// Re-exports everything from the generated client.
// Use `configureClient()` to set base URL and auth token.

// Generated SDK functions & types
export { healthIndex, type Options } from './client/sdk.gen';
export type {
  ClientOptions,
  HealthIndexData,
  HealthIndexResponse,
  HealthIndexResponses,
} from './client/types.gen';

// Valibot schemas (runtime validation)
export { vHealthIndexResponse } from './client/valibot.gen';

// TanStack Svelte Query helpers
export {
  healthIndexOptions,
  healthIndexQueryKey,
  type QueryKey,
} from './client/@tanstack/svelte-query.gen';

// Client configuration
export { configureClient, getClient } from './config';
export type { ClientConfig, SupabaseJwtGetter } from './config';

// Low-level client (for interceptors, custom requests)
export { client } from './client/client.gen';