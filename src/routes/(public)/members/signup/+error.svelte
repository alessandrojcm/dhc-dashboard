<script lang="ts">
import * as Sentry from "@sentry/sveltekit";
import { page } from "$app/state";
import { Button } from '$lib/components/ui/button';
import * as Alert from '$lib/components/ui/alert';

Sentry.captureMessage(
	`Signup error page loaded: ${page.error?.message}`,
	"error",
);
</script>

<svelte:head>
	<title>Something has gone wrong</title>
</svelte:head>

<div class="flex items-center justify-center w-2/3">
	<Alert.Root variant="destructive" class="max-w-md h-fit">
		<Alert.Title>Something has gone wrong, please try again</Alert.Title>
		<Alert.Description>
			{page.error?.message}
		</Alert.Description>
		<Button onclick={() => document.location.reload()}>Try again</Button>
	</Alert.Root>
</div>
