<script lang="ts">
	import { page } from '$app/state';
	import { Button } from '$lib/components/ui/button';
	import { Card } from '$lib/components/ui/card';
	import { DiscordLogo, ExclamationTriangle } from 'svelte-radix';
	import { Input } from '$lib/components/ui/input';
	import { Separator } from '$lib/components/ui/separator';
	import * as Alert from '$lib/components/ui/alert/index.js';
	import DHCLogo from '/src/assets/images/dhc-logo.png?enhanced';
	import authSchema from '$lib/schemas/authSchema';
	import { superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';

	const hash = $derived(page.url.hash.split('#')[1] as string);
	let errorMessage = $derived(new URLSearchParams(hash).get('error_description'));
	const urlMessage = $derived(page.url.searchParams.get('message'));

	const { data } = $props();

	const form = superForm(data.form, {
		validators: valibotClient(authSchema),
		validationMethod: 'oninput',
		resetForm: false,
		onSubmit: () => {
			errorMessage = '';
		}
	});

	const { form: formData, enhance, submitting, errors, message } = form;
</script>

<Card
	class="flex flex-col self-center w-[90%] sm:w-[80%] md:w-[70%] lg:w-[50%] max-w-md p-6 h-auto min-h-[24rem] justify-around items-center"
>
	<div class="md:hidden flex justify-center mb-4">
		<enhanced:img src={DHCLogo} alt="Dublin Hema Club Logo" class="w-24 h-24" />
	</div>
	<h2 class="prose font-bold prose-h2 text-2xl text-center">Log in to the DHC Dashboard</h2>
	{#if $message}
		<Alert.Root variant="success" class="max-w-md mt-4">
			<Alert.Title>Success</Alert.Title>
			<Alert.Description>{$message.success}</Alert.Description>
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

	<!-- Single Authentication Form with SuperForms -->
	<form method="POST" class="w-full max-w-xs space-y-6" use:enhance>
		<!-- Magic Link Login -->
		<div class="space-y-4">
			<div class="space-y-2">
				<label for="email" class="text-sm font-medium">Email</label>
				<Input
					type="email"
					id="email"
					name="email"
					bind:value={$formData.email}
					placeholder="your@email.com"
				/>
				{#if $errors.email}
					<p class="text-sm text-destructive mt-1">{$errors.email}</p>
				{/if}
			</div>
			<input type="hidden" name="auth_method" value="magic_link" />
			<Button type="submit" class="w-full" disabled={$submitting}>
				{$submitting && $formData.auth_method === 'magic_link'
					? 'Sending...'
					: 'Sign in with Magic Link'}
			</Button>
		</div>

		<!-- Separator -->
		<div class="flex items-center">
			<Separator class="flex-grow w-auto" />
			<span class="px-3 text-sm text-muted-foreground">OR</span>
			<Separator class="flex-grow w-auto" />
		</div>

		<!-- Discord Login -->
		<Button
			type="submit"
			class="w-full bg-[#5865F2] hover:bg-[#FFFFFF] hover:text-[#000000]"
			disabled={$submitting}
			name="auth_method"
			value="discord"
		>
			<DiscordLogo class="mr-2" />
			{$submitting && $formData.auth_method === 'discord' ? 'Redirecting...' : 'Login with Discord'}
		</Button>
	</form>
</Card>
