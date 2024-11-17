<script lang="ts">
	import '../app.css';
	import type { LayoutData } from './$types';
	import { type Snippet } from 'svelte';
	import { goto, invalidate } from '$app/navigation';

	let { children, data }: { children: Snippet; data: LayoutData } = $props();
	let session = $derived(data.session);
	let supabase = $derived(data.supabase);

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
	{@render children()}
</div>

<style lanb="postcss">
	.app {
		display: flex;
		flex-direction: column;
		min-height: 100vh;
	}
</style>
