<script lang="ts">
	import * as Card from '$lib/components/ui/card';
	import * as Form from '$lib/components/ui/form';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
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
	import { Checkbox } from '$lib/components/ui/checkbox';
	import { toast } from 'svelte-sonner';
	import { onDestroy } from 'svelte';

	const { data } = $props();

	const form = superForm(data.form, {
		validators: valibotClient(signupSchema),
		validationMethod: 'oninput',
		resetForm: false
	});
	const { form: formData, enhance, submitting, errors, message } = form;
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

	const sub = message.subscribe((m) => {
		if (m?.success) {
			toast.success(m.success, { position: 'top-right' });
		}
	});

	onDestroy(() => {
		sub();
	});
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
									<Form.Label for="firstName">First name</Form.Label>
									<Input {...props} bind:value={$formData.firstName} />
								{/snippet}
							</Form.Control>
							<Form.FieldErrors />
						</Form.Field>

						<Form.Field {form} name="lastName">
							<Form.Control>
								{#snippet children({ props })}
									<Form.Label for="lastName">Last name</Form.Label>
									<Input {...props} bind:value={$formData.lastName} />
								{/snippet}
							</Form.Control>
							<Form.FieldErrors />
						</Form.Field>
					</div>

					<Form.Field {form} name="dateOfBirth">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label for="dateOfBirth">Date of Birth</Form.Label>
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
								<Form.Label for="gender">Gender</Form.Label>
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
								<Form.Label for="pronouns">Pronouns</Form.Label>
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
								<Form.Label for="email">Email</Form.Label>
								<Input
									class="cursor-not-allowed bg-gray-300/50"
									readonly
									{...props}
									type="email"
									bind:value={$formData.email}
								/>
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
								<Form.Label for="phoneNumber">Phone Number</Form.Label>
								<Input
									type="tel"
									{...props}
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
								<Form.Label for="nextOfKin">Next of Kin</Form.Label>
								<Input {...props} bind:value={$formData.nextOfKin} />
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="nextOfKinNumber">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label for="nextOfKinNumber">Next of Kin Phone Number</Form.Label>
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
								<Form.Label for="weapon">Preferred Weapon</Form.Label>
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
								<Form.Label for="medicalConditions">Medical Conditions</Form.Label>
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
					<Form.Field {form} name="insuranceFormSubmitted" class="flex items-center gap-2">
						<Form.Control>
							{#snippet children({ props })}
								<Checkbox {...props} bind:checked={$formData.insuranceFormSubmitted} />
								<Form.Label
									style="margin-top: 0 !important"
									class={$errors?.insuranceFormSubmitted ? 'text-red-500' : ''}
									>Please make sure you have submitted HEMA Ireland's insurance form</Form.Label
								>
							{/snippet}
						</Form.Control>
					</Form.Field>
				</Tabs.Content>
			</Tabs.Root>
			<Button type="submit" class="w-full" disabled={$submitting}>
				{$submitting ? 'Saving...' : 'Save Changes'}
			</Button>
		</form>
	</Card.Content>
</Card.Root>