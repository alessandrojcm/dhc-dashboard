<script lang="ts">
	import { superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import { CreateWorkshopSchema } from '$lib/schemas/workshops';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Switch } from '$lib/components/ui/switch';
	import { Alert, AlertDescription } from '$lib/components/ui/alert';
	import * as Form from '$lib/components/ui/form';
	import Calendar25 from '$lib/components/calendar-25.svelte';
	import { CheckCircle } from 'lucide-svelte';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { goto } from '$app/navigation';
	import { getLocalTimeZone } from '@internationalized/date';
	import dayjs from 'dayjs';

	const { data } = $props();

	const form = superForm(data.form, {
		validators: valibotClient(CreateWorkshopSchema),
		validationMethod: 'onblur',
		onUpdated: ({ form }) => {
			if (form.message?.success) {
				window?.scrollTo({ top: 0, behavior: 'smooth' });
				setTimeout(() => goto('/dashboard/workshops'), 2000);
			}
		},

	});

	const { form: formData, enhance, submitting, message } = form;
	
	// Calendar state
	let calendarDate = $state<any>();
	let startTime = $state('10:30');
	let endTime = $state('12:30');

	function updateWorkshopDates() {
		if (calendarDate && startTime) {
			const date = calendarDate.toDate(getLocalTimeZone());
			const [hours, minutes] = startTime.split(':').map(Number);
			const newDate = new Date(date);
			newDate.setHours(hours, minutes, 0, 0);
			$formData.workshop_date = newDate;
		}
		
		if (calendarDate && endTime) {
			const date = calendarDate.toDate(getLocalTimeZone());
			const [hours, minutes] = endTime.split(':').map(Number);
			const newDate = new Date(date);
			newDate.setHours(hours, minutes, 0, 0);
			$formData.workshop_end_date = newDate;
		}
	}
</script>

<div class="max-w-4xl mx-auto p-6 space-y-8">
	<div class="flex justify-between items-center">
		<h1 class="text-3xl font-bold">Create Workshop</h1>
		<Button variant="outline" href="/dashboard/workshops">
			Back to Workshops
		</Button>
	</div>

	{#if $message?.success}
		<Alert variant="default" class="border-green-200 bg-green-50">
			<CheckCircle class="h-4 w-4 text-green-600" />
			<AlertDescription class="text-green-800">{$message.success}</AlertDescription>
		</Alert>
	{/if}

	{#if $message?.error}
		<Alert variant="destructive">
			<AlertDescription>{$message.error}</AlertDescription>
		</Alert>
	{/if}

	<form method="POST" use:enhance class="space-y-8 bg-white rounded-lg border shadow-sm p-6">
		<!-- Basic Information Section -->
		<div class="space-y-6">
			<h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Basic Information</h2>
			
			<div class="grid grid-cols-1 md:grid-cols-2 gap-6">
				<Form.Field {form} name="title">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Title</Form.Label>
							<Input
								{...props}
								bind:value={$formData.title}
								placeholder="Enter workshop title"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="location">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Location</Form.Label>
							<Input
								{...props}
								bind:value={$formData.location}
								placeholder="Enter workshop location"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>
			</div>

			<Form.Field {form} name="description">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>Description</Form.Label>
						<Textarea
							{...props}
							bind:value={$formData.description}
							placeholder="Enter workshop description"
							rows={4}
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>
		</div>

		<!-- Date & Time Section -->
		<div class="space-y-6">
			<h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Date & Time</h2>
			
			<Form.Field {form} name="workshop_date">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label required>Workshop Date & Time</Form.Label>
						<div class="bg-gray-50 rounded-lg p-4">
							<Calendar25
								id="workshop"
								bind:date={calendarDate}
								bind:startTime
								bind:endTime
								onDateChange={updateWorkshopDates}
								onStartTimeChange={updateWorkshopDates}
								onEndTimeChange={updateWorkshopDates}
							/>
						</div>
						<input
							id="workshop_date"
							type="datetime-local"
							hidden
							value={$formData.workshop_date ? dayjs($formData.workshop_date).format('YYYY-MM-DDTHH:mm:ss') : ''}
							name="workshop_date"
							readonly
						/>
						<input
							id="workshop_end_date"
							type="datetime-local"
							hidden
							value={$formData.workshop_end_date ? dayjs($formData.workshop_end_date).format('YYYY-MM-DDTHH:mm:ss') : ''}
							name="workshop_end_date"
							readonly
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>

			<!-- Hidden field to capture workshop_end_date validation errors -->
			<Form.Field {form} name="workshop_end_date">
				<Form.Control>
					{#snippet children()}
						<!-- This field is just for validation errors, no visible input -->
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>
		</div>

		<!-- Workshop Details Section -->
		<div class="space-y-6">
			<h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Workshop Details</h2>
			
			<div class="grid grid-cols-1 md:grid-cols-2 gap-6">
				<Form.Field {form} name="max_capacity">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Maximum Capacity</Form.Label>
							<Input
								{...props}
								type="number"
								min="1"
								bind:value={$formData.max_capacity}
								placeholder="Enter maximum capacity"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="refund_deadline_days">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Refund Deadline (days)</Form.Label>
							<Input
								{...props}
								type="number"
								min="0"
								bind:value={$formData.refund_deadline_days}
								placeholder="3"
							/>
							<p class="text-sm text-muted-foreground mt-1">
								Days before workshop when refunds are no longer available
							</p>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>
			</div>
		</div>

		<!-- Pricing & Access Section -->
		<div class="space-y-6">
			<h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Pricing & Access</h2>
			
			<Form.Field {form} name="is_public">
				<Form.Control>
					{#snippet children({ props })}
						<div class="flex items-center space-x-3 p-4 bg-blue-50 rounded-lg border border-blue-200">
							<Switch
								{...props}
								id="is_public"
								bind:checked={$formData.is_public}
							/>
							<div>
								<Form.Label for="is_public" class="text-base font-medium">Public Workshop</Form.Label>
								<p class="text-sm text-blue-700 mt-1">
									Enable this to allow non-members to register for the workshop
								</p>
							</div>
						</div>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>

			<div class="grid grid-cols-1 md:grid-cols-2 gap-6">
				<Form.Field {form} name="price_member">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label required>Member Price</Form.Label>
							<div class="relative">
								<span class="absolute left-3 top-1/2 transform -translate-y-1/2 text-sm text-muted-foreground">€</span>
								<Input
									{...props}
									type="number"
									min="0"
									step="0.01"
									class="pl-8"
									bind:value={$formData.price_member}
									placeholder="10.00"
								/>
							</div>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				{#if $formData.is_public}
					<Form.Field {form} name="price_non_member">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label required>Non-Member Price</Form.Label>
								<div class="relative">
									<span class="absolute left-3 top-1/2 transform -translate-y-1/2 text-sm text-muted-foreground">€</span>
									<Input
										{...props}
										type="number"
										min="0"
										step="0.01"
										class="pl-8"
										bind:value={$formData.price_non_member}
										placeholder="20.00"
									/>
								</div>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>
				{:else}
					<div class="flex items-center justify-center h-20 text-sm text-muted-foreground bg-gray-50 border border-dashed border-gray-300 rounded-lg">
						<div class="text-center">
							<p class="font-medium">Non-Member Pricing</p>
							<p class="text-xs">Available for public workshops only</p>
						</div>
					</div>
				{/if}
			</div>
		</div>

		<!-- Submit Section -->
		<div class="pt-6 border-t">
			<Button type="submit" disabled={$submitting} class="w-full h-12 text-lg">
				{#if $submitting}
					<LoaderCircle class="mr-2 h-5 w-5" />
					Creating Workshop...
				{:else}
					Create Workshop
				{/if}
			</Button>
		</div>
	</form>
</div>
