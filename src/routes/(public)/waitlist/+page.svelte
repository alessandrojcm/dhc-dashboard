<script lang="ts">
	import * as Form from '$lib/components/ui/form';
	import dayjs from 'dayjs';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { dateProxy, superForm } from 'sveltekit-superforms';
	import { getLocalTimeZone, fromDate } from '@internationalized/date';
	import * as Card from '$lib/components/ui/card';
	import { dev } from '$app/environment';
	import DatePicker from '$lib/components/ui/date-picker.svelte';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import beginnersWaitlist from '$lib/schemas/beginnersWaitlist';
	import SuperDebug from 'sveltekit-superforms';
	import { CheckCircled } from 'svelte-radix';
	import * as Alert from '$lib/components/ui/alert';
	import * as Select from '$lib/components/ui/select';
	import * as Tooltip from '$lib/components/ui/tooltip';
	import { AsYouType } from 'libphonenumber-js/min';
	import { HelpCircle } from 'lucide-svelte';

	const { data } = $props();
	const form = superForm(data.form, {
		validators: valibotClient(beginnersWaitlist)
	});
	const { form: formData, enhance, errors, message } = form;
	const dobProxy = dateProxy(form, 'dateOfBirth', { format: `date` });
	const dobValue = $derived.by(() => {
		if (!dayjs($formData.dateOfBirth).isValid() || dayjs($formData.dateOfBirth).isSame(dayjs())) {
			return undefined;
		}
		return fromDate(dayjs($formData.dateOfBirth).toDate(), getLocalTimeZone());
	});
	const formatedPhone = $derived.by(() => new AsYouType('IE').input($formData.phoneNumber));
	$inspect(data.genders);
</script>

<svelte:head>
	<title>Dublin Hema Club - Waitlist Registration</title>
</svelte:head>

{#snippet whyThisField(message: string)}
	<Tooltip.Provider>
		<Tooltip.Root>
			<Tooltip.Trigger>
				<HelpCircle class="h-4 w-4 text-muted-foreground" />
			</Tooltip.Trigger>
			<Tooltip.Content>
				{message}
			</Tooltip.Content>
		</Tooltip.Root>
	</Tooltip.Provider>
{/snippet}
<Card.Root class="self-center">
	<Card.Header>
		<Card.Title class="prose prose-h1 text-xl">Waitlist Form</Card.Title>
		<Card.Description class="prose">
			Thanks for your interest in Dublin Hema Club! Please sign up for our waitlist, we will contact
			you once a spot for our beginners workshop opens
		</Card.Description>
	</Card.Header>
	<Card.Content>
		{#if $message?.text}
			<Alert.Root variant="success">
				<CheckCircled class="h-4 w-4" />
				<Alert.Title>Thank you!</Alert.Title>
				<Alert.Description>{$message.text}</Alert.Description>
			</Alert.Root>
		{:else}
			<form method="POST" {form} use:enhance class="flex flex-col gap-4 items-stretch">
				<div class="flex gap-4 w-full justify-stretch">
					<Form.Field {form} name="firstName" class="flex-1">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label required>First name</Form.Label>
								<Input
									{...props}
									bind:value={$formData.firstName}
									placeholder="Enter your first name"
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="lastName" class="flex-1">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label required>Last name</Form.Label>
								<Input
									{...props}
									bind:value={$formData.lastName}
									placeholder="Enter your last name"
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>
				</div>

				<Form.Field {form} name="email">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Email</Form.Label>
							<Input
								type="email"
								{...props}
								bind:value={$formData.email}
								placeholder="Enter your email"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="phoneNumber">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Phone number</Form.Label>
							<Input
								type="tel"
								{...props}
								value={formatedPhone}
								onchange={(event) => {
									$formData.phoneNumber = event.target.value;
								}}
								placeholder="Enter your phone number"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="gender">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Gender</Form.Label>
							{@render whyThisField(
								'This helps us maintain a balanced and inclusive training environment'
							)}
							<Select.Root type="single" bind:value={$formData.gender} name={props.name}>
								<Select.Trigger {...props}>
									{#if $formData.gender}
										<p class="capitalize">{$formData.gender}</p>
									{:else}
										Select your gender
									{/if}
								</Select.Trigger>
								<Select.Content>
									{#each data.genders as gender}
										<Select.Item class="capitalize" value={gender} label={gender} />
									{/each}
								</Select.Content>
							</Select.Root>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>
				<Form.Field {form} name="pronouns">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Pronouns</Form.Label>
							{@render whyThisField(
								'This helps us maintain a balanced and inclusive training environment'
							)}
							<Input {...props} bind:value={$formData.pronouns} placeholder="Enter your pronouns" />
						{/snippet}
					</Form.Control>
					<Form.Description class={$errors?.pronouns ? 'text-red-500' : ''}
						>Please separate with slashes (e.g. they/them).</Form.Description
					>
				</Form.Field>

				<Form.Field {form} name="dateOfBirth">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Date of birth</Form.Label>
							{@render whyThisField(
								'For insurance reasons, HEMA practitioners need to be at least 16 years old'
							)}
							<DatePicker
								{...props}
								value={dobValue}
								onDateChange={(date) => {
									if (!date) {
										return;
									}
									$formData.dateOfBirth = date;
								}}
							/>
							<input id="dobInput" type="date" hidden value={$dobProxy} name={props.name} />
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="medicalConditions">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Any medical condition?</Form.Label>
							<Input
								type="textarea"
								{...props}
								bind:value={$formData.medicalConditions}
								placeholder="Enter any medical conditions"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Button type="submit">Submit</Button>
			</form>
		{/if}
	</Card.Content>
</Card.Root>
{#if false}
	<SuperDebug data={{ $formData, $errors, $message }} />
{/if}
