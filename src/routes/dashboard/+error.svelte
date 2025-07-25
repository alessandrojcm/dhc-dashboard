<script lang="ts">
	import { page } from '$app/state';
    import * as Alert from '$lib/components/ui/alert';
		console.error(page.error);
</script>

<div class="flex items-center justify-center min-h-screen">
	<Alert.Root variant="destructive" class="max-w-md">
		<Alert.Title>Error</Alert.Title>
		<Alert.Description>{page.error?.message}</Alert.Description>
	</Alert.Root>
</div>
