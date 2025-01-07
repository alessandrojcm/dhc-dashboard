<script lang="ts">
	import * as Alert from '$lib/components/ui/alert';
    import { page } from '$app/stores';
	console.log($page.error)
</script>

<svelte:head>
	<title>Something went wrong</title>
</svelte:head>

<div class="flex items-center justify-center h-[100vh] w-2/3">
	<Alert.Root variant="destructive" class="max-w-md h-fit">
		<Alert.Title>Error</Alert.Title>
		<Alert.Description>
			{$page.error?.message || 'An unexpected error occurred.'}
		</Alert.Description>
	</Alert.Root>
</div>
