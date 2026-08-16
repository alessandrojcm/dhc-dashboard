<script lang="ts">
import { Button } from "$lib/components/ui/button";
import { restartDiscordVerification } from "./data.remote";
</script>

<main class="mx-auto max-w-xl space-y-6 p-6">
	<p class="text-sm font-medium text-muted-foreground">
		Create your membership
	</p>
	<h1 class="text-3xl font-bold">Discord is temporarily unavailable</h1>
	<p class="text-muted-foreground">
		We could not finish Discord verification. No payment was started and no
		membership or sign-in session was created.
	</p>
	<p class="text-sm text-muted-foreground">
		Try again from this invitation when Discord is available.
	</p>
	<form {...restartDiscordVerification}>
		<Button type="submit" disabled={!!restartDiscordVerification.pending}>
			{restartDiscordVerification.pending
				? "Restarting..."
				: "Restart verification"}
		</Button>
	</form>
</main>
