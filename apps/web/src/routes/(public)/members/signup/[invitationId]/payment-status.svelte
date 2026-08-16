<script lang="ts">
import { Button } from "$lib/components/ui/button";
import { page } from "$app/state";
import type { PageServerData } from "./$types";

const { data }: { data: PageServerData } = $props();
</script>

<main class="mx-auto max-w-xl space-y-6 p-6">
	<p class="text-sm font-medium text-muted-foreground">
		Create your membership
	</p>
	<h1 class="text-3xl font-bold">
		{data.state === "paymentNeedsAction"
			? "Payment needs attention"
			: data.state === "paymentTerminal"
				? "Payment could not be completed"
				: "Payment in progress"}
	</h1>
	{#if data.discordVerified}
		<p class="text-muted-foreground">
			Your Discord account remains verified. You will not need to connect it
			again.
		</p>
	{/if}
	<p class="text-muted-foreground">
		{data.state === "paymentTerminal"
			? "Your verified acceptance is saved. Contact support before trying again."
			: "Your verified acceptance is saved. Completing payment will not create a second membership."}
	</p>
	{#if data.retryAllowed && data.state !== "paymentTerminal"}
		<Button href={`/members/signup/${page.params.invitationId}/resume`}>
			Retry completion
		</Button>
	{:else}
		<p class="text-sm text-muted-foreground">
			We are continuing automatically. You can safely return to this page later.
		</p>
	{/if}
</main>
