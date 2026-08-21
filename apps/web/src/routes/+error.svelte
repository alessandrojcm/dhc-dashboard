<script lang="ts">
import { page } from "$app/state";
import * as Alert from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";

// Unexpected errors are redacted to "Internal Error" before they reach the
// browser, so don't show that string to users — the real error is logged
// server-side by `logUnhandledServerError` in `hooks.server.ts`.
const isServerError = $derived((page.status ?? 500) >= 500);
const description = $derived(
	isServerError || !page.error?.message
		? "Something went wrong on our side. The error has been logged — please try again in a moment."
		: page.error.message,
);
</script>

<svelte:head>
	<title>{page.status ?? 500} · Dublin Hema Club</title>
</svelte:head>

<div class="flex flex-col items-center justify-center gap-4 min-h-screen px-4">
	<Alert.Root variant="destructive" class="max-w-md">
		<Alert.Title>Something went wrong</Alert.Title>
		<Alert.Description>{description}</Alert.Description>
	</Alert.Root>
	<!-- `/` redirects to /dashboard for signed-in members and /auth otherwise,
	     so this is a safe recovery point for public and private routes alike. -->
	<Button href="/" variant="outline">Back to home</Button>
</div>
