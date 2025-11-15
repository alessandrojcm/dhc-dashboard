<script lang="ts">
	import * as Form from '$lib/components/ui/form';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { dateProxy, superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import { inviteValidationSchema } from '$lib/schemas/inviteValidationSchema';
	import { ArrowRightIcon } from 'lucide-svelte';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { toast } from 'svelte-sonner';
	import { page } from '$app/state';
	import * as Alert from '$lib/components/ui/alert';
	import { goto } from '$app/navigation';
	import dayjs from 'dayjs';
	import { fromDate, getLocalTimeZone } from '@internationalized/date';
	import DatePicker from '$lib/components/ui/date-picker.svelte';

	const invitationId = $derived(page.params.invitationId);

	let { isVerified = $bindable(false) } = $props();

	// Create a form with the invite validation schema
	const form = superForm(
		{
			dateOfBirth: page.url.searchParams.get('dateOfBirth') || '',
			email: page.url.searchParams.get('email') || ''
		},
		{
			validators: valibotClient(inviteValidationSchema),
			resetForm: false,
			validationMethod: 'onblur',
			SPA: true,
			onUpdate: async ({ form, cancel }) => {
				try {
					const response = await fetch(`/api/invite/${invitationId}`, {
						method: 'POST',
						headers: {
							'Content-Type': 'application/json'
						},
						body: JSON.stringify({
							email: form.data.email,
							dateOfBirth: form.data.dateOfBirth
						})
					});

					if (response.ok) {
						isVerified = true;
						goto(`/members/signup/${invitationId}`, {
							replaceState: true
						});
					} else {
						toast.error('Invalid invitation details. Please check your email and date of birth.');
						cancel();
					}
				} catch (error) {
					toast.error('An error occurred. Please try again.');
					console.error('Error verifying invitation:', error);
					cancel();
				}
			}
		}
	);

	const { form: formData, enhance, submitting } = form;
	const dobProxy = dateProxy(form, 'dateOfBirth', { format: `date` });
	const dobValue = $derived.by(() => {
		if (!dayjs($formData.dateOfBirth).isValid() || dayjs($formData.dateOfBirth).isSame(dayjs())) {
			return undefined;
		}
		return fromDate(dayjs($formData.dateOfBirth).toDate(), getLocalTimeZone());
	});
</script>

{#if isVerified}
	<div class="space-y-6">
		<Alert.Root variant="success" class="w-full mb-6">
			<Alert.Title>Invitation Verified!</Alert.Title>
			<Alert.Description>
				Your invitation has been successfully verified. Please complete your membership signup
				below.
			</Alert.Description>
		</Alert.Root>
	</div>
{:else}
	<div class="max-w-md mx-auto p-6">
		<h4 class="font-bold mb-6">Verify Your Invitation</h4>
		<p class="mb-6 text-gray-600">
			Please enter your email and date of birth to verify your invitation.
		</p>

		<form method="POST" class="space-y-6" use:enhance>
			<Form.Field {form} name="email">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>Email</Form.Label>
						<Input
							{...props}
							type="email"
							bind:value={$formData.email}
							placeholder="Enter your email address"
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
							{...props}
							value={dobValue}
							onDateChange={(date) => {
								if (!date) {
									return;
								}
								$formData.dateOfBirth = dayjs(date).format('YYYY-MM-DD');
							}}
						/>
						<input id="dobInput" type="date" hidden value={$dobProxy} name={props.name} />
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>

			<Button type="submit" class="w-full" disabled={$submitting}>
				{#if $submitting}
					<LoaderCircle />
				{:else}
					Verify Invitation
					<ArrowRightIcon class="ml-2 h-4 w-4" />
				{/if}
			</Button>
		</form>
	</div>
{/if}
