<script lang="ts">
	import * as Alert from '$lib/components/ui/alert';
	import { page } from '$app/stores';
</script>

<svelte:head>
	<title>Something has gone wrong</title>
</svelte:head>

<div class="flex items-center justify-center h-[100vh] w-2/3">
	<Alert.Root variant="destructive" class="max-w-md h-fit">
		<Alert.Title>Something has gone wrong</Alert.Title>
		<Alert.Description>
			{$page.error?.message}
		</Alert.Description>
	</Alert.Root>
</div>
