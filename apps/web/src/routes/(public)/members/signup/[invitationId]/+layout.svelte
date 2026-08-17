<script lang="ts">
import * as Card from "$lib/components/ui/card";

const { children } = $props();
</script>

<svelte:head>
	<title>Join Dublin Hema Club</title>
</svelte:head>

<Card.Root class="w-full max-w-4xl gap-0 overflow-hidden py-0">
	<Card.Header class="border-b border-border/70 bg-muted/25 px-6 py-5 sm:px-8">
		<Card.Title class="text-xl sm:text-2xl">Join Dublin HEMA Club</Card.Title>
		<Card.Description class="mt-1 max-w-2xl leading-relaxed">
			A few quick steps, then you are ready to train, organise, and belong.
		</Card.Description>
	</Card.Header>
	<Card.Content class="px-0 pb-0">
		{@render children()}
	</Card.Content>
</Card.Root>
