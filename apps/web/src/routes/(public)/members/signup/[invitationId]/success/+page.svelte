<script lang="ts">
import * as Alert from "$lib/components/ui/alert";
import { resolve } from "$app/paths";
import { Button } from "$lib/components/ui/button";
</script>

<Alert.Root variant="success" class="w-full">
	<Alert.Title>Membership created</Alert.Title>
	<Alert.Description>
		Sign in with your membership email to continue.
	</Alert.Description>
	<Button href={resolve("/auth")} class="mt-2 w-fit">Go to sign in</Button>
</Alert.Root>
