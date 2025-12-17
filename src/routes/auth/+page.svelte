<script lang="ts">
	import { page } from "$app/state";
	import { Button } from "$lib/components/ui/button";
	import { Card } from "$lib/components/ui/card";
	import { DiscordLogo, ExclamationTriangle } from "svelte-radix";
	import { Input } from "$lib/components/ui/input";
	import { Separator } from "$lib/components/ui/separator";
	import * as Alert from "$lib/components/ui/alert/index.js";
	import * as Field from "$lib/components/ui/field";
	import DHCLogo from "/src/assets/images/dhc-logo.png?enhanced";
	import { magicLinkAuth, discordAuth } from "./data.remote";

	const hash = $derived(page.url.hash.split("#")[1] as string);
	let errorMessage = $derived(
		new URLSearchParams(hash).get("error_description"),
	);
	const urlMessage = $derived(page.url.searchParams.get("message"));
</script>

<Card
	class="flex flex-col self-center w-[90%] sm:w-[80%] md:w-[70%] lg:w-[50%] max-w-md p-6 h-auto min-h-[24rem] justify-around items-center"
>
	<div class="md:hidden flex justify-center mb-4">
		<enhanced:img
			src={DHCLogo}
			alt="Dublin Hema Club Logo"
			class="w-24 h-24"
		/>
	</div>
	<h2 class="prose font-bold prose-h2 text-2xl text-center">
		Log in to the DHC Dashboard
	</h2>

	{#if magicLinkAuth.result?.success}
		<Alert.Root variant="success" class="max-w-md mt-4">
			<Alert.Title>Success</Alert.Title>
			<Alert.Description>{magicLinkAuth.result.success}</Alert.Description
			>
		</Alert.Root>
	{/if}

	{#if urlMessage}
		<Alert.Root variant="success" class="max-w-md mt-4">
			<Alert.Title>Success</Alert.Title>
			<Alert.Description>{urlMessage}</Alert.Description>
		</Alert.Root>
	{/if}

	{#if errorMessage}
		<Alert.Root variant="destructive" class="max-w-md mt-4">
			<ExclamationTriangle class="h-4 w-4" />
			<Alert.Title>Error</Alert.Title>
			<Alert.Description>{errorMessage}</Alert.Description>
		</Alert.Root>
	{/if}

	<!-- Magic Link Form -->
	<form {...magicLinkAuth} class="w-full max-w-xs space-y-4">
		<Field.Field>
			{@const fieldProps = magicLinkAuth.fields.email.as("email")}
			<Field.Label for={fieldProps.name}>Email</Field.Label>
			<Input
				{...fieldProps}
				id={fieldProps.name}
				placeholder="your@email.com"
			/>
			{#each magicLinkAuth.fields.email.issues() as issue}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>

		<Button type="submit" class="w-full">Send Magic Link</Button>
	</form>

	<!-- Separator -->
	<div class="flex items-center w-full max-w-xs">
		<Separator class="flex-grow w-auto" style="width: auto" />
		<span class="px-3 text-sm text-muted-foreground">OR</span>
		<Separator class="flex-grow w-auto" style="width: auto" />
	</div>

	<!-- Discord OAuth Form -->
	<form {...discordAuth} class="w-full max-w-xs">
		<Button
			type="submit"
			class="w-full bg-[#5865F2] hover:bg-[#FFFFFF] hover:text-[#000000]"
		>
			<DiscordLogo class="mr-2" />
			Login with Discord
		</Button>
	</form>
</Card>
