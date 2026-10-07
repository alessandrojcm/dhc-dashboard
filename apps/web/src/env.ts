import { defineEnvVars } from "@sveltejs/kit/env";

// Optional runtime variables are `undefined` when unset, as `$env/dynamic/*`
// was: call sites fall back with `??` (API_BASE_URL) or guard on presence, so
// they must not be coerced to an empty string.
const optional = (input: string | undefined) => input;

export const variables = defineEnvVars({
	PUBLIC_STRIPE_KEY: { public: true, static: true },
	PUBLIC_API_BASE_URL: { public: true, schema: optional },
	PUBLIC_SITE_URL: { public: true, static: true },
	API_BASE_URL: { schema: optional },
	STRIPE_SECRET_KEY: { schema: optional },
	GROQ_API_KEY: { schema: optional },
	// Shared with Phoenix; authenticates the forwarded `x-dhc-client-ip` on
	// server-side API calls (see #lib/server/api-client.ts).
	TRUSTED_FORWARDING_SECRET: { schema: optional },
	PUBLIC_PHOENIX_SOCKET_URL: { public: true, schema: optional },
});
