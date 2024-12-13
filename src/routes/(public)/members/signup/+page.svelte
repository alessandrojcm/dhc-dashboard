<script lang="ts">
	import * as Form from '$lib/components/ui/form';
	import dayjs from 'dayjs';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import * as Card from '$lib/components/ui/card';
	import { superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import { memberSignupSchema } from '$lib/schemas/membersSignup';
	import { AsYouType } from 'libphonenumber-js/min';
	import { Checkbox } from '$lib/components/ui/checkbox';

	const { data } = $props();

	const form = superForm(data.form, {
		validators: valibotClient(memberSignupSchema),
		validationMethod: 'onblur'
	});
	const { form: formData, enhance, submitting, errors } = form;
	const formatedPhone = $derived.by(() => new AsYouType('IE').input(data.userData.phoneNumber));
	const formatedNextOfKinPhone = $derived.by(() =>
		new AsYouType('IE').input($formData.nextOfKinNumber)
	);
</script>

<svelte:head>
	<title>Join Dublin Hema Club</title>
</svelte:head>

<Card.Root class="w-full max-w-2xl">
	<Card.Header>
		<Card.Title>Join Dublin Hema Club</Card.Title>
		<Card.Description>We are glad you decided to join us! Please fill up the following details</Card.Description>
	</Card.Header>
	<Card.Content>
		<form method="POST" class="space-y-6" use:enhance>
			<div class="grid grid-cols-2 gap-4">
				<div>
					<p>First Name</p>
					<p class="text-sm text-gray-600">{data.userData.firstName}</p>
				</div>
				<div>
					<p>Last Name</p>
					<p class="text-sm text-gray-600">{data.userData.lastName}</p>
				</div>
				<div>
					<p>Email</p>
					<p class="text-sm text-gray-600">{data.userData.email}</p>
				</div>
				<div>
					<p>Date of Birth</p>
					<p class="text-sm text-gray-600">{dayjs(data.userData.dateOfBirth).format('DD/MM/YYYY')}</p>
				</div>
				<div>
					<p>Gender</p>
					<p class="text-sm text-gray-600 capitalize">{data.userData.gender}</p>
				</div>
				<div>
					<p>Pronouns</p>
					<p class="text-sm text-gray-600 capitalize">{data.userData.pronouns}</p>
				</div>
				<div>
					<p>Phone Number</p>
					<p class="text-sm text-gray-600">{formatedPhone}</p>
				</div>
				<div>
					<p>Medical Conditions</p>
					<p class="text-sm text-gray-600">
						{!data.userData.medicalConditions ? 'N/A' : data.userData.medicalConditions}
					</p>
				</div>
			</div>
			<div class="space-y-4">
				<Form.Field {form} name="nextOfKin">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Next of Kin</Form.Label>
							<Input
								{...props}
								bind:value={$formData.nextOfKin}
								placeholder="Full name of your next of kin"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="nextOfKinNumber">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Next of Kin Phone Number</Form.Label>
							<Input
								type="tel"
								{...props}
								placeholder="Enter your next of kin's phone number"
								value={formatedNextOfKinPhone}
								onchange={(event) => {
									$formData.nextOfKinNumber = event.target.value;
								}}
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>
				<Form.Field {form} name="insuranceFormSubmitted" class="flex items-center gap-2">
					<Form.Control>
						{#snippet children({ props })}
							<Checkbox {...props} bind:checked={$formData.insuranceFormSubmitted} />
							<Form.Label style="margin-top: 0 !important" class={$errors?.insuranceFormSubmitted ? 'text-red-500':''}>Please make sure you have submitted HEMA Ireland's insurance form</Form.Label>
						{/snippet}
					</Form.Control>
				</Form.Field>
			</div>
			<div class="flex justify-between">
				<Button type="submit" class="ml-auto" disabled={$submitting}>
					{$submitting ? 'Signing Up...' : 'Complete Sign Up'}
				</Button>
			</div>
		</form>
	</Card.Content>
</Card.Root>
