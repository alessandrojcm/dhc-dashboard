<script lang="ts">
	import * as Alert from '$lib/components/ui/alert';
	import { page } from '$app/stores';
</script>

<div class="flex items-center justify-center h-[100vh]">
	<Alert.Root variant="destructive" class="max-w-md">
		<Alert.Title>Something has gone wrong</Alert.Title>
		<Alert.Description>
			{$page.error?.message}
		</Alert.Description>
	</Alert.Root>
</div>
