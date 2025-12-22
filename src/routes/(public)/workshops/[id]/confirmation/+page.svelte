<script lang="ts">
import { page } from '$app/state';
import { Alert, AlertTitle, AlertDescription } from '$lib/components/ui/alert';
import { Button } from '$lib/components/ui/button';
import { CheckCircle } from 'lucide-svelte';

const sessionId = page.url.searchParams.get("session_id");
</script>

<div class="container mx-auto px-4 py-8">
	<div class="max-w-md mx-auto">
		<Alert class="border-green-200 bg-green-50">
			<CheckCircle class="h-4 w-4 text-green-600" />
			<AlertTitle class="text-green-800">Registration Successful!</AlertTitle>
			<AlertDescription class="text-green-700">
				Thank you for registering for the workshop. You will receive a confirmation email shortly
				with all the details.
			</AlertDescription>
		</Alert>

		<div class="mt-6 text-center">
			<Button onclick={() => (window.location.href = '/')}>Return to Home</Button>
		</div>

		{#if sessionId}
			<p class="text-sm text-gray-500 mt-4 text-center">
				Reference: {sessionId}
			</p>
		{/if}
	</div>
</div>
