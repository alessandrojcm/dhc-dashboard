<script lang="ts">
	import { page } from '$app/stores';
	import { Button } from '$lib/components/ui/button';
	import { Card } from '$lib/components/ui/card';
	import { DiscordLogo, ExclamationTriangle } from 'svelte-radix';
	import * as Alert from '$lib/components/ui/alert/index.js';

	const hash = $page.url.hash.split('#')[1] as string;
	const errorMessage = new URLSearchParams(hash).get('error_description');
	const message = $page.url.searchParams.get('message');
</script>

<Card class="flex flex-col self-center w-2/4 h-96 justify-around items-center">
	<h2 class="prose font-bold prose-h2 text-2xl">Log in to the DHC Dashboard</h2>
	{#if message}
		<Alert.Root variant="success" class="max-w-md">
			<Alert.Title>Success</Alert.Title>
			<Alert.Description>{message}</Alert.Description>
		</Alert.Root>
	{/if}
	<form method="POST" class="flex justify-center">
		<Button type="submit" class="bg-[#5865F2] hover:bg-[#FFFFFF] hover:text-[#000000]">
			<DiscordLogo />
			Login with Discord</Button
		>
	</form>
	{#if errorMessage}
		<Alert.Root variant="destructive" class="max-w-md">
			<ExclamationTriangle class="h-4 w-4" />
			<Alert.Title>Error</Alert.Title>
			<Alert.Description>{errorMessage}</Alert.Description>
		</Alert.Root>
	{/if}
</Card>
