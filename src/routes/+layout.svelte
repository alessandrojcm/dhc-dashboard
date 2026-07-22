<script lang="ts">
import "../app.css";
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import { SvelteQueryDevtools } from "@tanstack/svelte-query-devtools";
import { Toaster } from "$lib/components/ui/sonner/index";
import posthog from "posthog-js";
import type { Snippet } from "svelte";
import { onMount } from "svelte";
import { browser, dev } from "$app/environment";
import { configureBrowserApiClient } from "$lib/api-client";
import type { LayoutData } from "./$types";

const { children, data }: { children: Snippet; data: LayoutData } = $props();
const session = $derived(data.session);
const queryClient = new QueryClient();

if (browser) {
	// ALE-164: the dashboard authenticates through the Phoenix `_dhc_session`
	// cookie. The browser sends it automatically with
	// `credentials: 'include'` on every request to the Phoenix API; no
	// Supabase JWT getter is needed. `configureClient` sets `credentials`
	// once so the generated `@dhc/api-client` carries the cookie.
	configureBrowserApiClient();
}

onMount(() => {
	if (browser && !dev) {
		// Initialize PostHog
		posthog.init("phc_8UeWfJf2mUh6QRm4BGgj38bMOJLGmdHmdGR280hMLPL", {
			api_host: "https://us.i.posthog.com",
			person_profiles: "identified_only",
			capture_pageview: true,
			capture_pageleave: true,
		});
	}

	if (browser && session?.principal) {
		posthog.identify(session.principal.id, {
			email: session.principal.email,
		});
	}
});

// ALE-164: no Supabase `onAuthStateChange` listener. Session invalidation
// is explicit: `invalidate("phoenix:session")` (e.g. after sign-in or
// sign-out) re-runs the root layout load, which re-reads the session
// projection from Phoenix. Child components (e.g. the dashboard logout
// handler) call `invalidateAll()` directly.
</script>

<div class="app">
	<QueryClientProvider client={queryClient}>
		{@render children()}
		<SvelteQueryDevtools />
	</QueryClientProvider>
	<Toaster />
</div>

<style lang="postcss">
	.app {
		display: flex;
		flex-direction: column;
		min-height: 100vh;
	}
</style>
