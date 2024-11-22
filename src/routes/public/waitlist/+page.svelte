<script lang="ts">
	import * as Form from '$lib/components/ui/form';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { superForm } from 'sveltekit-superforms';
	import * as Card from '$lib/components/ui/card';
	import { dev } from '$app/environment';
	import DatePicker from '$lib/components/ui/date-picker.svelte';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import beginnersWaitlist from '$lib/schemas/beginnersWaitlist';
	import SuperDebug from 'sveltekit-superforms';
	import { fromDate, getLocalTimeZone } from '@internationalized/date';

	export let data;
	const form = superForm(data.form, {
		validators: valibotClient(beginnersWaitlist)
	});
	const { form: formData, enhance } = form;
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
						<Input {...props} bind:value={$formData.lastName} placeholder="Enter your last name" />
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
							bind:value={$formData.phoneNumber}
							placeholder="Enter your phone number"
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>

			<Form.Field {form} name="dateOfBirth">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>Date of birth</Form.Label>
						<DatePicker
							value={$formData.dateOfBirth
								? fromDate($formData.dateOfBirth, getLocalTimeZone())
								: null}
							onDateChange={(date) => form.form.update((curr) => ({ ...curr, dateOfBirth: date }))}
						/>
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
	</Card.Content>
</Card.Root>
{#if dev}
	<SuperDebug data={form} />
{/if}
