<script lang="ts">
<<<<<<< HEAD
import { page } from "$app/state";
import * as Alert from "$lib/components/ui/alert";
import * as Sentry from "@sentry/sveltekit";

Sentry.captureMessage(`Error page loaded: ${page.error?.message}`, "error");
=======
	import { page } from "$app/state";
	import * as Alert from "$lib/components/ui/alert";
	import * as Sentry from "@sentry/sveltekit";

	Sentry.captureMessage(`Error page loaded: ${page.error?.message}`, "error");
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
</script>

<svelte:head>
	<title>Something went wrong</title>
</svelte:head>

<div class="flex items-center justify-center h-[100vh] w-2/3">
	<Alert.Root variant="destructive" class="max-w-md h-fit">
		<Alert.Title>Error</Alert.Title>
		<Alert.Description>
			{page.error?.message || "An unexpected error occurred."}
		</Alert.Description>
	</Alert.Root>
</div>
