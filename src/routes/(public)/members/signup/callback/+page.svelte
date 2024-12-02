<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/stores';
	import * as Alert from '$lib/components/ui/alert';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { onMount } from 'svelte';

	let error = $state(false);
	onMount(() => {
		const token = new URLSearchParams($page.url.hash.split('#')[1]).get('access_token');
		if (!token) {
			error = true;
		} else {
			goto(`/members/signup?access_token=${token}`);
		}
	});
</script>

<div class="flex items-center justify-center h-[100vh]">
	{#if error}
		<Alert.Root variant="destructive" class="max-w-md">
			<Alert.Title>Invalid invite</Alert.Title>
			<Alert.Description>
				This invite is invalid of has expired, pease contact us to request a new one.
			</Alert.Description>
		</Alert.Root>
	{:else}
		<LoaderCircle />
	{/if}
</div>
