<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import * as Alert from '$lib/components/ui/alert';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { onMount } from 'svelte';

	let error = $state(false);
	onMount(() => {
		const token = new URLSearchParams(page.url.hash.split('#')[1]).get('access_token');
		if (!token) {
			error = true;
		} else {
			fetch('/members/signup/callback', {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: `Bearer ${token}`
				},
			}).then((res) => {
				if (res.ok) {
					goto(res.headers.get('Location') || '/members/signup', {
						replaceState: true
					});
				} else {
					error = true;
				}
			});
		}
	});
</script>


<svelte:head>
	<title>Join Dublin Hema Club</title>
</svelte:head>

<div class="flex items-center justify-center h-[100vh]">
	{#if error}
		<Alert.Root variant="destructive" class="max-w-md">
			<Alert.Title>Invalid invite</Alert.Title>
			<Alert.Description>
				This invite is invalid or has expired, pease contact us to request a new one.
			</Alert.Description>
		</Alert.Root>
	{:else}
		<LoaderCircle />
	{/if}
</div>
