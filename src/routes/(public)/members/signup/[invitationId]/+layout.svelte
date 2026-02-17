<script lang="ts">
	import * as Card from "$lib/components/ui/card";
	import DHCLogo from "/src/assets/images/dhc-logo.png?enhanced";

	const { children } = $props();
</script>

<svelte:head>
	<title>Join Dublin Hema Club</title>
</svelte:head>

<Card.Root class="w-full max-w-2xl max-h-[90vh]">
	<Card.Header>
		<div class="md:hidden flex justify-center mb-4">
			<enhanced:img
				src={DHCLogo}
				alt="Dublin Hema Club Logo"
				class="w-24 h-24"
			/>
		</div>
		<Card.Title>Join Dublin Hema Club</Card.Title>
		<Card.Description
			>We are glad you decided to join us! These are the personal details
			we have from you, if anything is not right, you will be able to
			change it later. Please fill up your next of kin data and the
			payment info below.
		</Card.Description>
	</Card.Header>
	<Card.Content class="h-auto md:max-h-[72svh] max-h-[60svh] overflow-y-auto">
		{@render children()}
	</Card.Content>
</Card.Root>
