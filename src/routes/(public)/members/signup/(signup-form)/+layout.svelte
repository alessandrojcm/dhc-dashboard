<script lang="ts">
	import * as Card from '$lib/components/ui/card';

	const { children } = $props();
</script>

<svelte:head>
	<title>Join Dublin Hema Club</title>
</svelte:head>

<Card.Root class="w-full max-w-2xl max-h-[90vh]">
	<Card.Header>
		<Card.Title>Join Dublin Hema Club</Card.Title>
		<Card.Description
			>We are glad you decided to join us! Please fill up the following details and complete your
			first payment</Card.Description
		>
	</Card.Header>
	<Card.Content class="max-h-[80svh] overflow-y-auto">
		{@render children()}
	</Card.Content>
</Card.Root>
