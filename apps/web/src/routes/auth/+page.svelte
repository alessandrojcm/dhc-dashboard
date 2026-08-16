<script lang="ts">
import { DiscordLogo, ExclamationTriangle } from "svelte-radix";
import { page } from "$app/state";
import { publicApiUrl } from "$lib/api-client";
import * as Alert from "$lib/components/ui/alert/index.js";
import { Button } from "$lib/components/ui/button";
import { Card } from "$lib/components/ui/card";
import * as Field from "$lib/components/ui/field";
import { Input } from "$lib/components/ui/input";
import { Separator } from "$lib/components/ui/separator";
import { magicLinkAuth } from "./data.remote";

let { data } = $props();

const hash = $derived(page.url.hash.split("#")[1] ?? "");
const discordFailed = $derived(
	page.url.searchParams.get("discord") === "failed",
);
const errorMessage = $derived(
	discordFailed
		? "Discord sign-in failed. Try a magic link instead."
		: new URLSearchParams(hash).get("error_description"),
);
const urlMessage = $derived(page.url.searchParams.get("message"));
const discordAuthUrl = publicApiUrl("/auth/discord");
</script>

<Card class="w-full gap-7 border-t-4 border-t-secondary p-6 sm:p-8">
	<div class="space-y-2 text-center sm:text-left">
		<p class="text-xs font-bold uppercase tracking-[0.2em] text-primary">
			Welcome back
		</p>
		<h2 class="text-3xl leading-tight sm:text-4xl">Enter the club desk</h2>
		<p class="text-sm leading-6 text-muted-foreground">
			Use your club email or continue with Discord.
		</p>
	</div>

	{#if magicLinkAuth.result?.success}
		<Alert.Root variant="success" class="max-w-md mt-4">
			<Alert.Title>Success</Alert.Title>
			<Alert.Description>{magicLinkAuth.result.success}</Alert.Description>
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
	<form {...magicLinkAuth} class="w-full space-y-4">
		<Field.Field>
			{@const fieldProps = magicLinkAuth.fields.email.as(
				"email",
				data.prefillEmail ?? "",
			)}
			<Field.Label for={fieldProps.name}>Email</Field.Label>
			<Input
				{...fieldProps}
				id={fieldProps.name}
				placeholder="your@email.com"
			/>
			{#each magicLinkAuth.fields.email.issues() as issue (issue.message)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>

		<Button type="submit" class="w-full">Send Magic Link</Button>
	</form>

	<!-- Separator -->
	<div class="flex w-full items-center">
		<Separator class="flex-grow w-auto" style="width: auto" />
		<span class="px-3 text-sm text-muted-foreground">OR</span>
		<Separator class="flex-grow w-auto" style="width: auto" />
	</div>

	<!-- Discord OAuth starts as a top-level navigation to Phoenix/Assent. -->
	<form method="GET" action={discordAuthUrl} class="w-full">
		<Button
			type="submit"
			class="w-full bg-[#5865F2] text-white shadow-none hover:bg-[#4752c4]"
		>
			<DiscordLogo class="mr-2" />
			Login with Discord
		</Button>
	</form>
</Card>
