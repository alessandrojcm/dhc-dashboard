<script lang="ts">
import { Button } from "$lib/components/ui/button";
import { continueToPayment, restartDiscordVerification } from "./data.remote";

let { discord }: { discord?: { username?: string; avatarUrl?: string } } =
	$props();
</script>

<div class="max-w-xl space-y-6">
	<div
		class="flex items-center gap-4 rounded-xl border border-primary/15 bg-primary/5 p-4"
	>
		{#if discord?.avatarUrl}
			<img class="size-12 rounded-full" src={discord.avatarUrl} alt="" />
		{/if}
		<div>
			<p
				class="text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground"
			>
				Connected account
			</p>
			<p class="mt-1 font-semibold">
				@{discord?.username ?? "Discord account"}
			</p>
		</div>
	</div>
	<p class="text-sm text-muted-foreground">
		This is the Discord account that will be associated with your membership.
		Its display name may change.
	</p>
	<div class="flex flex-col gap-3 sm:flex-row sm:flex-wrap">
		<form {...continueToPayment}>
			<Button size="lg" type="submit" disabled={!!continueToPayment.pending}>
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
	</div>
</div>
