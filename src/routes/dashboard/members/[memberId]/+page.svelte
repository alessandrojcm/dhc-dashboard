<script lang="ts">
	import * as Card from '$lib/components/ui/card';
	import * as Form from '$lib/components/ui/form';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import * as Select from '$lib/components/ui/select';
	import { Textarea } from '$lib/components/ui/textarea';
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
	import { whyThisField } from '$lib/components/ui/why-this-field.svelte';
	import * as RadioGroup from '$lib/components/ui/radio-group/index.js';
	import { Skeleton } from '$lib/components/ui/skeleton/index.js';
	import { ExternalLink } from 'lucide-svelte';

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

	$inspect($errors);
</script>

<Card.Root class="w-full max-w-4xl mx-auto">
	<Card.Header>
		<Card.Title>Member Information</Card.Title>
		<Card.Description>View and edit your membership details</Card.Description>
	</Card.Header>
	<Card.Content class="min-h-96 max-h-[80svh] overflow-y-auto">
		<form method="POST" action="?/update-profile" use:enhance class="space-y-8">
			<div class="grid grid-cols-1 md:grid-cols-2 gap-6">
				<div class="space-y-6">
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
					<Button variant="outline" type="submit" formaction="?/payment-settings" class="w-full"
						>Manage payment settings <ExternalLink class="ml-2 h-4 w-4" /></Button
					>
				</div>
				<div class="space-y-6">
					<Form.Field {form} name="gender">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label for="gender">Gender</Form.Label>
								<Select.Root type="single" bind:value={$formData.gender} name={props.name}>
									{#await data.genders}
										<Select.Trigger class="w-full capitalize" {...props} loading>
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
									class="capitalize"
									{...props}
									bind:value={$formData.pronouns}
									placeholder="e.g. she/her, they/them"
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>
					<Form.Field {form} name="weapon">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label for="weapon">Preferred Weapon</Form.Label>
								<Select.Root type="multiple" bind:value={$formData.weapon} name={props.name}>
									{#await data.weapons}
										<Select.Trigger class="capitalize" {...props} loading>
											{$formData.weapon?.length > 0
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
					<Form.Fieldset {form} name="socialMediaConsent">
						<span class="flex items-center gap-2">
							<p class="text-sm font-medium">Social media consent</p>
							{@render whyThisField(
								'We sometimes take pictures for our social media, please indicate if you are comfortable with this'
							)}
						</span>
						<RadioGroup.Root
							name="socialMediaConsent"
							class="flex justify-start"
							bind:value={$formData.socialMediaConsent}
						>
							<div class="flex items-center space-x-3 space-y-0">
								<Form.Control>
									{#snippet children({ props })}
										<RadioGroup.Item value="no" {...props} />
										<Form.Label class="font-normal">No</Form.Label>
									{/snippet}
								</Form.Control>
							</div>
							<div class="flex items-center space-x-3 space-y-0">
								<Form.Control>
									{#snippet children({ props })}
										<RadioGroup.Item value="yes_unrecognizable" {...props} />
										<Form.Label class="font-normal">If not recognizable (wearing a mask)</Form.Label
										>
									{/snippet}
								</Form.Control>
							</div>
							<div class="flex items-center space-x-3 space-y-0">
								<Form.Control>
									{#snippet children({ props })}
										<RadioGroup.Item value="yes_recognizable" {...props} />
										<Form.Label class="font-normal">Yes</Form.Label>
									{/snippet}
								</Form.Control>
							</div>
						</RadioGroup.Root>
						<Form.FieldErrors />
					</Form.Fieldset>
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
				</div>
			</div>
			<div class="space-y-6">
				<h3 class="text-lg font-semibold">Emergency Contact</h3>
				<div class="grid grid-cols-1 md:grid-cols-2 gap-6">
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
					{#await data.insuranceFormLink}
						<Skeleton class="h-8 w-full" />
					{:then insuranceFormLink}
						<Form.Field {form} name="insuranceFormSubmitted" class="flex items-center gap-2">
							<Form.Control>
								{#snippet children({ props })}
									<Checkbox {...props} bind:checked={$formData.insuranceFormSubmitted} />
									<Form.Label
										style="margin-top: 0 !important"
										class={$errors?.insuranceFormSubmitted ? 'text-red-500' : ''}
										>Please make sure you have submitted HEMA Ireland's <a
											class="text-blue-500 underline"
											href={insuranceFormLink}
											target="_blank">insurance form</a
										></Form.Label
									>
								{/snippet}
							</Form.Control>
						</Form.Field>
					{/await}
				</div>
			</div>

			<Button type="submit" class="w-full" disabled={$submitting}>
				{$submitting ? 'Saving...' : 'Save Changes'}
			</Button>
		</form>
	</Card.Content>
</Card.Root>
