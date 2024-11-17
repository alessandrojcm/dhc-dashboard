<script lang="ts">
	import '../app.css';
	import type { LayoutData } from './$types';
	import { type Snippet } from 'svelte';
	import { invalidate } from '$app/navigation';

	let { children, data }: {children: Snippet, data: LayoutData} = $props();
	let session = $derived(data.session)
	let supabase = $derived(data.supabase)

	$effect(() => {
		const { data } = supabase.auth.onAuthStateChange((_, newSession) => {
			if (newSession?.expires_at !== session?.expires_at) {
				invalidate('supabase:auth');
			}
		});

		return () => data.subscription.unsubscribe();
	})
</script>

<div class="app">
	<main>
		{@render children()}
	</main>
</div>

<style lanb="postcss">
	.app {
		display: flex;
		flex-direction: column;
		min-height: 100vh;
	}

	main {
		flex: 1;
		display: flex;
		flex-direction: column;
		padding: 1rem;
		width: 100%;
		max-width: 64rem;
		margin: 0 auto;
		box-sizing: border-box;
	}
</style>
