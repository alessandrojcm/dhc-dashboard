<script lang="ts">
	import * as Card from '$lib/components/ui/card';
	import * as Form from '$lib/components/ui/form';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { Label } from '$lib/components/ui/label';
	import * as Select from '$lib/components/ui/select';
	import { Textarea } from '$lib/components/ui/textarea';
	import * as Tabs from '$lib/components/ui/tabs';
	import { superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import signupSchema from '$lib/schemas/membersSignup';
	import DatePicker from '$lib/components/ui/date-picker.svelte';
	import { dateProxy } from 'sveltekit-superforms';
	import { getLocalTimeZone, fromDate } from '@internationalized/date';
	import dayjs from 'dayjs';
	import { AsYouType } from 'libphonenumber-js/min';
	import FormDescription from '$lib/components/ui/form/form-description.svelte';
	import { Description } from 'formsnap';

	const { data } = $props();

	const form = superForm(data.form, {
		validators: valibotClient(signupSchema),
		validationMethod: 'onblur'
	});
	const { form: formData, enhance, submitting } = form;
	const dobProxy = dateProxy(form, 'dateOfBirth', { format: `date` });
	const dobValue = $derived.by(() => {
		if (!dayjs($formData.dateOfBirth).isValid() || dayjs($formData.dateOfBirth).isSame(dayjs())) {
			return undefined;
		}
		return fromDate(dayjs($formData.dateOfBirth).toDate(), getLocalTimeZone());
	});
	const formatedPhone = $derived.by(() => new AsYouType('IE').input($formData.phoneNumber));
	const formatedNextOfKinPhone = $derived.by(() =>
		new AsYouType('IE').input($formData.nextOfKinNumber)
	);
	$inspect($formData);
</script>

<Card.Root class="w-full max-w-4xl mx-auto">
	<Card.Header>
		<Card.Title>Member Information</Card.Title>
		<Card.Description>View and edit your membership details</Card.Description>
	</Card.Header>
	<Card.Content class="min-h-96">
		<form method="POST" use:enhance class="space-y-8">
			<Tabs.Root value="personal" class="w-full">
				<Tabs.List class="grid w-full grid-cols-3">
					<Tabs.Trigger value="personal">Personal</Tabs.Trigger>
					<Tabs.Trigger value="contact">Contact</Tabs.Trigger>
					<Tabs.Trigger value="membership">Membership</Tabs.Trigger>
				</Tabs.List>

				<Tabs.Content value="personal" class="space-y-4">
					<div class="grid grid-cols-2 gap-4">
						<Form.Field {form} name="firstName">
							<Form.Control>
								{#snippet children({ props })}
									<Label for="firstName">First name</Label>
									<Input {...props} bind:value={$formData.firstName} />
								{/snippet}
							</Form.Control>
							<Form.FieldErrors />
						</Form.Field>

						<Form.Field {form} name="lastName">
							<Form.Control>
								{#snippet children({ props })}
									<Label for="lastName">Last name</Label>
									<Input {...props} bind:value={$formData.lastName} />
								{/snippet}
							</Form.Control>
							<Form.FieldErrors />
						</Form.Field>
					</div>

					<Form.Field {form} name="dateOfBirth">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="dateOfBirth">Date of Birth</Label>
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

					<Form.Field {form} name="gender">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="gender">Gender</Label>
								<Select.Root type="single" bind:value={$formData.gender} name={props.name}>
									{#await data.genders}
										<Select.Trigger class="w-full" {...props} loading>
											{$formData.gender ? $formData.gender : 'Select your gender'}
										</Select.Trigger>
									{:then genders}
										<Select.Trigger class="w-full" {...props}>
											{$formData.gender ? $formData.gender : 'Select your gender'}
										</Select.Trigger>
										<Select.Content>
											{#each genders as gender}
												<Select.Item value={gender} class="capitalize">{gender}</Select.Item>
											{/each}
										</Select.Content>
									{/await}
								</Select.Root>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="pronouns">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="pronouns">Pronouns</Label>
								<Input
									{...props}
									bind:value={$formData.pronouns}
									placeholder="e.g. she/her, they/them"
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>
				</Tabs.Content>

				<Tabs.Content value="contact" class="space-y-4">
					<Form.Field {form} name="email">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="email">Email</Label>
								<Input class="cursor-not-allowed bg-gray-300/50" readonly {...props} type="email" bind:value={$formData.email} />
							{/snippet}
						</Form.Control>
						<Form.FormDescription>
							Please contact us if you need to change your email.
						</Form.FormDescription>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="phoneNumber">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="phoneNumber">Phone Number</Label>
								<Input
									{...props}
									type="tel"
									value={formatedPhone}
									onchange={(event) => {
										$formData.phoneNumber = event.target.value;
									}}
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="nextOfKin">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="nextOfKin">Next of Kin</Label>
								<Input {...props} bind:value={$formData.nextOfKin} />
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="nextOfKinNumber">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="nextOfKinNumber">Next of Kin Phone Number</Label>
								<Input
									{...props}
									type="tel"
									value={formatedNextOfKinPhone}
									onchange={(event) => {
										$formData.nextOfKinNumber = event.target.value;
									}}
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>
				</Tabs.Content>

				<Tabs.Content value="membership" class="space-y-4">
					<Form.Field {form} name="weapon">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="weapon">Preferred Weapon</Label>
								<Select.Root type="multiple" bind:value={$formData.weapon}>
									{#await data.weapons}
										<Select.Trigger class="capitalize" {...props} loading>
											{$formData.weapon
												? $formData.weapon.join(', ')
												: 'Select your preferred weapon(s)'}
										</Select.Trigger>
									{:then weapons}
										<Select.Trigger class="capitalize" {...props}>
											{$formData.weapon
												? $formData.weapon.join(', ').replace(/[_-]/g, ' ')
												: 'Select your preferred weapon(s)'}
										</Select.Trigger>
										<Select.Content>
											{#each weapons as weapon}
												<Select.Item class="capitalize" value={weapon}
													>{weapon.replace(/[_-]/g, ' ')}</Select.Item
												>
											{/each}
										</Select.Content>
									{/await}
								</Select.Root>
							{/snippet}
						</Form.Control>
						<Form.FormDescription>You can select more than one</Form.FormDescription>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="medicalConditions">
						<Form.Control>
							{#snippet children({ props })}
								<Label for="medicalConditions">Medical Conditions</Label>
								<Textarea
									{...props}
									bind:value={$formData.medicalConditions}
									placeholder="Please list any medical conditions or allergies you have. If none, leave blank."
									class="min-h-[100px]"
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>
				</Tabs.Content>
			</Tabs.Root>
			<Button type="submit" class="w-full" disabled={$submitting}>
				{$submitting ? 'Saving...' : 'Save Changes'}
			</Button>
		</form>
	</Card.Content>
</Card.Root>
