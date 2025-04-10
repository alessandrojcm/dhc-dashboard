<script lang="ts">
	import '../app.css';
	import type { LayoutData } from './$types';
	import Toaster from '$lib/components/ui/sonner/sonner.svelte';
	import { type Snippet } from 'svelte';
	import { goto, invalidate } from '$app/navigation';
	import { QueryClient, QueryClientProvider } from '@tanstack/svelte-query';
	import { SvelteQueryDevtools } from '@tanstack/svelte-query-devtools';

	let { children, data }: { children: Snippet; data: LayoutData } = $props();
	let session = $derived(data.session);
	let supabase = $derived(data.supabase);
	const queryClient = new QueryClient();

	$effect(() => {
		const { data } = supabase.auth.onAuthStateChange((event, newSession) => {
			if (event === 'SIGNED_OUT') {
				goto('/auth', {
					replaceState: true
				});
			}
			if (newSession?.expires_at !== session?.expires_at) {
				invalidate('supabase:auth');
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

<style lanb="postcss">
	.app {
		display: flex;
		flex-direction: column;
		min-height: 100vh;
	}
</style>
