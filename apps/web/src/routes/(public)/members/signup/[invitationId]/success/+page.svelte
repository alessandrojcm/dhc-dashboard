<script lang="ts">
import * as Alert from "$lib/components/ui/alert";
import { resolve } from "$app/paths";
import { Button } from "$lib/components/ui/button";
</script>

<Alert.Root variant="success" class="w-full">
	<Alert.Title>Thank You for Joining!</Alert.Title>
	<Alert.Description>
		Your membership has been created. You are not signed in. Go to the normal
		sign-in page and use your membership email to continue.
	</Alert.Description>
	<Button href={resolve("/auth")} class="mt-2 w-fit">Go to sign in</Button>
</Alert.Root>
