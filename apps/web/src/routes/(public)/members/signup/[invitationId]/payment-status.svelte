<script lang="ts">
import { Button } from "$lib/components/ui/button";
import { page } from "$app/state";
</script>

<main class="mx-auto max-w-xl space-y-6 p-6">
	<p class="text-sm font-medium text-muted-foreground">
		Create your membership
	</p>
	<h1 class="text-3xl font-bold">Payment in progress</h1>
	<p class="text-muted-foreground">
		Your verified acceptance is saved. Completing payment will not create a
		second membership.
	</p>
	<Button href={`/members/signup/${page.params.invitationId}/resume`}>
		Retry completion
	</Button>
</main>
