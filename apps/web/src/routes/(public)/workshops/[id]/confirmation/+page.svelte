<script lang="ts">
import { Alert, AlertTitle, AlertDescription } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import * as Card from "$lib/components/ui/card";
import { CircleCheckBig } from "@lucide/svelte";
</script>

<div class="container mx-auto px-4 py-8">
	<div class="mx-auto max-w-md">
		<Card.Root>
			<Card.Header>
				<Card.Title>Workshop registration complete</Card.Title>
				<Card.Description>Your place has been confirmed.</Card.Description>
			</Card.Header>
			<Card.Content>
				<Alert class="border-green-200 bg-green-50">
					<CircleCheckBig class="h-4 w-4 text-green-600" />
					<AlertTitle class="text-green-800">Registration confirmed</AlertTitle>
					<AlertDescription class="text-green-700">
						We will send the workshop details by email.
					</AlertDescription>
				</Alert>
			</Card.Content>
			<Card.Footer class="justify-center">
				<Button onclick={() => window.close()}>Close</Button>
			</Card.Footer>
		</Card.Root>
	</div>
</div>
