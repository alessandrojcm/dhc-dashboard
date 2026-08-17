<script lang="ts">
import { page } from "$app/state";
import { Button } from "$lib/components/ui/button";
</script>

<div class="max-w-xl space-y-6">
	<p class="text-muted-foreground">
		Discord is a required step before payment. We will ask you to sign in to the
		Discord account you want linked to your new membership.
	</p>
	<p class="text-sm text-muted-foreground">
		Your membership has not been created and no payment has started.
	</p>
	<div
		class="rounded-xl border border-primary/15 bg-primary/5 p-4 text-sm leading-6 text-muted-foreground"
	>
		You will return here automatically after authorising Dublin HEMA Club in
		Discord.
	</div>
	<Button size="lg" href={`/members/signup/${page.params.invitationId}/discord`}
		>Continue to Discord</Button
	>
</div>
