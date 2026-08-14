<script lang="ts">
import * as Alert from "$lib/components/ui/alert";
import { resolve } from "$app/paths";
import { Button } from "$lib/components/ui/button";
</script>

<Alert.Root variant="success" class="w-full">
	<Alert.Title>Thank You for Joining!</Alert.Title>
	<Alert.Description>
		Your membership has been created. You are not signed in. Continue to the
		normal sign-in page with your membership email.
	</Alert.Description>
	<Button href={resolve("/auth")} class="mt-2 w-fit">Go to sign in</Button>
</Alert.Root>
