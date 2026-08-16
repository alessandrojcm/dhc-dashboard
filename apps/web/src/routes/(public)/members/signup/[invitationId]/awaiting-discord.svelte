<script lang="ts">
import { page } from "$app/state";
import { Button } from "$lib/components/ui/button";
</script>

<main class="mx-auto max-w-xl space-y-6 p-6">
	<p class="text-sm font-medium text-muted-foreground">
		Create your membership
	</p>
	<h1 class="text-3xl font-bold">Connect Discord</h1>
	<p class="text-muted-foreground">
		Discord is a required step before payment. We will ask you to sign in to the
		Discord account you want linked to your new membership.
	</p>
	<p class="text-sm text-muted-foreground">
		Your membership has not been created and no payment has started.
	</p>
	<Button href={`/members/signup/${page.params.invitationId}/discord`}
		>Continue to Discord</Button
	>
</main>
