<script lang="ts">
	import { Alert, AlertDescription, AlertTitle } from '$lib/components/ui/alert';
	import { Button } from '$lib/components/ui/button';
	import { Card } from '$lib/components/ui/card';
	import DatePicker from '$lib/components/ui/date-picker.svelte';
	import * as Form from '$lib/components/ui/form/index.js';
	import { Input } from '$lib/components/ui/input';
	import PhoneInput from '$lib/components/ui/phone-input.svelte';
	import { ScrollArea } from '$lib/components/ui/scroll-area';
	import { Separator } from '$lib/components/ui/separator';
	import * as Sheet from '$lib/components/ui/sheet/index.js';
	import {
		adminInviteSchema,
		type AdminInviteSchemaOutput,
		bulkInviteSchema,
		type BulkInviteSchemaOutput
	} from '$lib/schemas/adminInvite';
	import { fromDate, getLocalTimeZone } from '@internationalized/date';
	import dayjs from 'dayjs';
	import { Info, Loader, Plus, Trash2 } from 'lucide-svelte';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import { dateProxy, superForm, type SuperValidated } from 'sveltekit-superforms/client';

	const props: {
		inviteForm: SuperValidated<AdminInviteSchemaOutput, any, AdminInviteSchemaOutput>;
		bulkInviteForm: SuperValidated<BulkInviteSchemaOutput, any, BulkInviteSchemaOutput>;
	} = $props();

	let isOpen = $state(false);

	// Single invite form
	const form = superForm(props.inviteForm, {
		validators: valibotClient(adminInviteSchema),
		applyAction: false,
		resetForm: true,
		validationMethod: 'onblur'
	});

	const { form: formData, message, reset: resetForm, validateForm } = form;

	const bulkInviteForm = superForm(props.bulkInviteForm, {
		taintedMessage: null,
		dataType: 'json',
		validationMethod: 'onsubmit',
		validators: valibotClient(bulkInviteSchema),
		onResult: ({ result }: { result: any }) => {
			if (result.type === 'success') {
				resetBulkForm();
			}
		}
	});

	const {
		form: bulkFormData,
		message: bulkMessage,
		reset: resetBulkForm,
		enhance: bulkEnhance,
		submitting: bulkSubmitting,
	} = bulkInviteForm;
	const dobProxy = dateProxy(form, 'dateOfBirth', { format: `date` });
	const dobValue = $derived.by(() => {
		if (!dayjs($formData.dateOfBirth).isValid() || dayjs($formData.dateOfBirth).isSame(dayjs())) {
			return undefined;
		}
		return fromDate(dayjs($formData.dateOfBirth).toDate(), getLocalTimeZone());
	});

	// Add current invite to the list
	async function addInviteToList() {
		const result = await validateForm({ update: true });
		if (!result.valid) {
			return;
		}
		const { firstName, lastName, email, phoneNumber, dateOfBirth, expirationDays } = $formData;

		// Only add if we have at least email filled out
		if (email) {
			$bulkFormData.invites = [
				...$bulkFormData.invites,
				{
					firstName: firstName || '',
					lastName: lastName || '',
					email,
					phoneNumber: phoneNumber || '',
					dateOfBirth: dateOfBirth || new Date(),
					expirationDays: expirationDays || 7
				}
			];

			// Clear the form for the next invite
			resetForm({
				newState: {
					dateOfBirth: new Date(),
					expirationDays: 7
				}
			});
		}
	}

	// Remove an invite from the list
	function removeInvite(index: number) {
		$bulkFormData.invites = $bulkFormData.invites.filter((_: any, i: number) => i !== index);
	}

	// Clear all invites
	function clearAllInvites() {
		$bulkFormData.invites = [];
	}
	$inspect($bulkMessage)
</script>

<Button variant="outline" onclick={() => (isOpen = true)}>Invite Members</Button>

<Sheet.Root bind:open={isOpen}>
	<Sheet.Content class="w-[400px] sm:w-[540px]" side="right">
		<Sheet.Header>
			<Sheet.Title>Invite Members</Sheet.Title>
			<Sheet.Description>Add new members to the club by sending them invitations.</Sheet.Description
			>
		</Sheet.Header>

		<div class="py-4 space-y-6">
			<!-- Invite Form -->
			<form class="space-y-4">
				{#if $bulkMessage}
					<Alert variant={$bulkMessage.success ? 'success' : 'destructive'}>
						<Info class="h-4 w-4" />
						<AlertTitle>
							{$bulkMessage.success ? 'Success!' : 'Something went wrong'}
						</AlertTitle>
						<AlertDescription>
							{$bulkMessage.success || $bulkMessage.failure}
						</AlertDescription>
					</Alert>
				{/if}

				<div class="grid grid-cols-2 gap-4">
					<!-- First Name -->
					<Form.Field {form} name="firstName">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label>First Name</Form.Label>
								<Input {...props} bind:value={$formData.firstName} />
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

					<!-- Last Name -->
					<Form.Field {form} name="lastName">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label>Last Name</Form.Label>
								<Input {...props} bind:value={$formData.lastName} />
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>
				</div>

				<!-- Email -->
				<Form.Field {form} name="email">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Email</Form.Label>
							<Input {...props} type="email" bind:value={$formData.email} />
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="dateOfBirth">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Date of birth</Form.Label>
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

				<!-- Phone Number -->
				<Form.Field {form} name="phoneNumber">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Phone Number</Form.Label>
							<PhoneInput
								placeholder="Enter your phone number"
								{...props}
								bind:phoneNumber={$formData.phoneNumber}
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<!-- Expiration Days -->
				<Form.Field {form} name="expirationDays">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Expiration (days)</Form.Label>
							<Input
								{...props}
								type="number"
								min="1"
								max="365"
								bind:value={$formData.expirationDays}
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>
			</form>
			<div class="flex justify-between gap-2">
				<form method="POST" action="?/createBulkInvites" use:bulkEnhance>
					<input type="hidden" name="invites" value={JSON.stringify($bulkFormData.invites)} />
					<Button
						type="submit"
						class="w-full"
						disabled={$bulkFormData.invites.length === 0 || $bulkSubmitting}
					>
						{#if $bulkSubmitting}
							<Loader class="mr-2 h-4 w-4" />
						{/if}
						Send {$bulkFormData.invites.length} Invitations
					</Button>
				</form>
				<Button
					type="button"
					variant="outline"
					onclick={addInviteToList}
				>
					<Plus class="mr-2 h-4 w-4" />
					Add to List
				</Button>
			</div>

			<Separator />

			<!-- Invite List -->
			<div class="space-y-4">
				<div class="flex items-center justify-between">
					<h3 class="text-lg font-medium">Invite List ({$bulkFormData.invites.length})</h3>
					{#if $bulkFormData.invites.length > 0}
						<Button variant="outline" size="sm" onclick={clearAllInvites}>Clear All</Button>
					{/if}
				</div>

				{#if $message}
					<Alert
						variant={$message.success ? 'success' : $message.warning ? 'default' : 'destructive'}
					>
						<Info class="h-4 w-4" />
						<AlertTitle>
							{$message.success ? 'Success!' : $message.warning ? 'Partial Success' : 'Error!'}
						</AlertTitle>
						<AlertDescription>
							{$message.success || $message.warning || $message.failure}
						</AlertDescription>
					</Alert>
				{/if}
				<ScrollArea class="h-[300px] pr-4">
					{#if $bulkFormData.invites.length === 0}
						<div class="text-center py-8 text-muted-foreground">
							<p>No invites added yet. Add members using the form above.</p>
						</div>
					{:else}
						<div class="space-y-3">
							{#each $bulkFormData.invites as invite, index}
								<Card class="p-3">
									<div class="flex justify-between items-start">
										<div>
											<p class="font-medium">
												{invite.firstName}
												{invite.lastName}
											</p>
											<p class="text-sm text-muted-foreground">{invite.email}</p>
											{#if invite.phoneNumber}
												<p class="text-xs text-muted-foreground">{invite.phoneNumber}</p>
											{/if}
										</div>
										<Button
											variant="ghost"
											size="icon"
											class="h-8 w-8"
											onclick={() => removeInvite(index)}
										>
											<Trash2 class="h-4 w-4" />
										</Button>
									</div>
								</Card>
							{/each}
						</div>
					{/if}
				</ScrollArea>
			</div>
		</div>
	</Sheet.Content>
</Sheet.Root>
