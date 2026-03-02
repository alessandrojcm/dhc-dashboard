<script lang="ts">
import * as Alert from "$lib/components/ui/alert";
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
import { Button } from "$lib/components/ui/button";

const { data } = $props();
</script>

<Alert.Root variant="success" class="w-full">
	<Alert.Title>Thank You for Joining!</Alert.Title>
	<Alert.Description>
		Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive
		a Discord invite by email shortly.
	</Alert.Description>
	<Button onclick={() => goto(resolve('/dashboard'))} class="mt-2 w-fit">Go to Dashboard</Button>
</Alert.Root>
