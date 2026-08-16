<script lang="ts">
import { Button } from "$lib/components/ui/button";
import { continueToPayment, restartDiscordVerification } from "./data.remote";

let { discord }: { discord?: { username?: string; avatarUrl?: string } } =
	$props();
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
	<form {...continueToPayment}>
		<Button type="submit" disabled={!!continueToPayment.pending}>
			{continueToPayment.pending ? "Continuing..." : "Continue to payment"}
		</Button>
	</form>
	<form {...restartDiscordVerification}>
		<Button
			type="submit"
			variant="outline"
			disabled={!!restartDiscordVerification.pending}
		>
			{restartDiscordVerification.pending
				? "Restarting..."
				: "Use a different Discord account"}
		</Button>
	</form>
</main>
