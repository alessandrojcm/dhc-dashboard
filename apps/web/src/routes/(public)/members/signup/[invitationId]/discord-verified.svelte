<script lang="ts">
import { page } from "$app/state";
import { Button } from "$lib/components/ui/button";
import type { PageServerData } from "./$types";
import PaymentForm from "./payment-form.svelte";

let {
	data,
	discord,
}: {
	data: PageServerData;
	discord?: { username?: string; avatarUrl?: string };
} = $props();
</script>

<main class="mx-auto max-w-xl space-y-6 p-6">
	<p class="text-sm font-medium text-muted-foreground">
		Create your membership
	</p>
	<h1 class="text-3xl font-bold">Discord verified</h1>
	{#if discord?.avatarUrl}
		<img class="h-12 w-12 rounded-full" src={discord.avatarUrl} alt="" />
	{/if}
	<p class="text-muted-foreground">
		Verified Discord account: @{discord?.username ?? "Discord account"}
	</p>
	<p class="text-sm text-muted-foreground">
		This is the Discord account that will be associated with your membership.
		Its display name may change.
	</p>
	<PaymentForm {data} />
	<form
		method="POST"
		action={`/members/signup/${page.params.invitationId}/discord/cancel`}
	>
		<Button type="submit" variant="outline"
			>Use a different Discord account</Button
		>
	</form>
</main>
