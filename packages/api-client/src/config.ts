// Client configuration wrapper for @dhc/api-client
//
// Usage in SvelteKit:
//   import { configureClient, getClient } from '@dhc/api-client';
//
//   // At app startup (e.g., +layout.svelte or hooks):
//   configureClient({
//     baseUrl: 'http://localhost:4000/api',
//     getAuthToken: () => supabaseAuth.getSession().access_token,
//   });
//
//   // Then call SDK functions:
//   import { healthIndex } from '@dhc/api-client';
//   const { data } = await healthIndex();

import { client } from './client/client.gen';

export type SupabaseJwtGetter = () =>
  | Promise<string | undefined>
  | string
  | undefined;

export interface ClientConfig {
  /** Base URL for the Phoenix API (e.g. "http://localhost:4000/api") */
  baseUrl: string;
  /** Optional getter that returns a Supabase JWT. Called on every request. */
  getAuthToken?: SupabaseJwtGetter;
}

/**
 * Configure the shared client instance with a base URL and optional JWT getter.
 * Call this once at app startup before making any API calls.
 */
export function configureClient(config: ClientConfig): void {
  client.setConfig({
    baseUrl: config.baseUrl,
    auth: config.getAuthToken
      ? async () => {
          const token = await config.getAuthToken?.();
          return token ?? undefined;
        }
      : undefined,
  });
}

/**
 * Returns the configured client instance.
 * Useful for interceptors or advanced use cases.
 */
export function getClient() {
  return client;
}