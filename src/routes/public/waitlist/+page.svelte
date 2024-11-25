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

	const { data } = $props();
	const form = superForm(data.form, {
		validators: valibotClient(beginnersWaitlist)
	});
	const { form: formData, enhance, errors, message } = form;
	const dobProxy = dateProxy(form, 'dateOfBirth', { format: `date` });
	const dobValue = $derived.by(() => {
		return fromDate(dayjs($formData.dateOfBirth).toDate(), getLocalTimeZone());
	});
	const formatedPhone = $derived.by(() => new AsYouType('IE').input($formData.phoneNumber));
	$inspect(data.genders);
</script>

<svelte:head>
	<title>Dublin Hema Club - Waitlist Registration</title>
</svelte:head>
<Card.Root class="self-center w-96 mt-[15%]">
	<Card.Header>
		<Card.Title class="prose prose-h1 text-xl">Waitlist Form</Card.Title>
		<Card.Description class="prose">
			Thanks for your interest in Dublin Hema Club! Please sign up for our waitlist, we will contact
			you once a spot for our beginners workshop opens</Card.Description
		>
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
				<Form.Field {form} name="firstName">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>First name</Form.Label>
							<Input
								{...props}
								bind:value={$formData.firstName}
								placeholder="Enter your first name"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="lastName">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Last name</Form.Label>
							<Input
								{...props}
								bind:value={$formData.lastName}
								placeholder="Enter your last name"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="email">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Email</Form.Label>
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
							<Form.Label>Phone number</Form.Label>
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
							<Form.Label>Gender</Form.Label>
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
					<Tooltip.Provider>
						<Tooltip.Root>
							<Tooltip.Trigger>
								<Form.Description class="underline">Why do we need this?</Form.Description>
							</Tooltip.Trigger>
							<Tooltip.Content side="bottom">
								<p>We use this information to better understand the preferences of our members.</p>
							</Tooltip.Content>
						</Tooltip.Root>
					</Tooltip.Provider>
					<Form.FieldErrors />
				</Form.Field>
				<Form.Field {form} name="pronouns">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Pronouns</Form.Label>
							<Input {...props} bind:value={$formData.pronouns} placeholder="Enter your pronouns" />
						{/snippet}
					</Form.Control>
					<Tooltip.Provider>
						<Tooltip.Root>
							<Tooltip.Trigger>
								<Form.Description class="underline">Why do we need this?</Form.Description>
							</Tooltip.Trigger>
							<Tooltip.Content side="bottom">
								<p>We use this information to better understand the preferences of our members.</p>
							</Tooltip.Content>
						</Tooltip.Root>
					</Tooltip.Provider>
				</Form.Field>

				<Form.Field {form} name="dateOfBirth">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Date of birth</Form.Label>
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
					<Tooltip.Provider>
						<Tooltip.Root>
							<Tooltip.Trigger>
								<Form.Description class="underline">Why do we need this?</Form.Description>
							</Tooltip.Trigger>
							<Tooltip.Content side="bottom">
								<p>For insurance reasons, HEMA practitioners need to be at least 16 years old.</p>
							</Tooltip.Content>
						</Tooltip.Root>
					</Tooltip.Provider>
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
{#if dev}
	<SuperDebug data={{ $formData, $errors, $message }} />
{/if}
