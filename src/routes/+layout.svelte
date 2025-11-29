<script lang="ts">
import "../app.css";
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import {SvelteQueryDevtools} from "@tanstack/svelte-query-devtools";
import {Toaster} from "$lib/components/ui/sonner/index";
import posthog from "posthog-js";
import type { Snippet } from "svelte";
import { onMount } from "svelte";
import { browser, dev } from "$app/environment";
import { goto, invalidate } from "$app/navigation";
import type { LayoutData } from "./$types";

const { children, data }: { children: Snippet; data: LayoutData } = $props();
const session = $derived(data.session);
const supabase = $derived(data.supabase);
const queryClient = new QueryClient();

onMount(() => {
	if (browser && !dev) {
		// Initialize PostHog
		posthog.init("phc_8UeWfJf2mUh6QRm4BGgj38bMOJLGmdHmdGR280hMLPL", {
			api_host: "https://us.i.posthog.com",
			person_profiles: "identified_only", // or 'always' to create profiles for anonymous users as well
			capture_pageview: true,
			capture_pageleave: true,
		});
	}
});

$effect(() => {
	const { data } = supabase.auth.onAuthStateChange((event, newSession) => {
		if (event === "SIGNED_OUT") {
			goto("/auth", {
				replaceState: true,
				invalidateAll: true,
			});
		}
		if (newSession?.expires_at !== session?.expires_at) {
			invalidate("supabase:auth");
		}
		if (newSession?.user) {
			posthog.identify(newSession.user.id, {
				email: newSession.user.email,
				metadata: newSession.user.user_metadata,
			});
		}
	});

	return () => data.subscription.unsubscribe();
});
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
