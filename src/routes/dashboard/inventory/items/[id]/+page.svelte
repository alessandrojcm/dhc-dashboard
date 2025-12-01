<script lang="ts">
	import {
		Card,
		CardContent,
		CardDescription,
		CardHeader,
		CardTitle
	} from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import * as Form from '$lib/components/ui/form';
	import { Input } from '$lib/components/ui/input';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { Label } from '$lib/components/ui/label';
	import SuperDebug, { superForm } from 'sveltekit-superforms';
	import { toast } from 'svelte-sonner';
	import { ArrowLeft, Package, Edit, X, FolderOpen, Tags, Clock, Plus } from 'lucide-svelte';
	import dayjs from 'dayjs';
	import relativeTime from 'dayjs/plugin/relativeTime';
	import { buildContainerHierarchy } from '$lib/utils/inventory-form';
	import { dev } from '$app/environment';

	dayjs.extend(relativeTime);
	let { data } = $props();
	const { item: initialItem, containers, canEdit } = data;

	// Track the current item state (will be updated after successful edits)
	let currentItem = $state(initialItem);

	// Make history reactive so it updates after invalidateAll
	const currentHistory = $derived(data.history);

	let isEditMode = $state(false);
	let attributeErrors = $state<Record<string, string>>({});

	// Use current item for display
	const displayItem = $derived(currentItem);
	const hierarchicalContainers = buildContainerHierarchy(containers);

	const form = superForm(data.form, {
		dataType: 'json',
		resetForm: false,
		invalidateAll: true,
		onResult({ result }) {
			// Check if the action succeeded (not just form validation)
			if (result.type === 'success') {
				// Update the current item with the returned data
				if (result.data?.item) {
					currentItem = result.data.item;
				}
				toast.success('Item updated successfully');
				isEditMode = false;
			} else if (result.type === 'failure') {
				toast.error(result.data?.form?.message || 'Failed to update item');
			}
		},
		onError({ result }) {
			console.error('Form submission error:', result);
			toast.error(result.error?.message || 'Failed to update item');
		}
	});

	const { form: formData, enhance, delayed } = form;

	// Use the display item's category since it can't be changed
	const categoryAttributes = $derived(displayItem.category?.available_attributes || []);
	const selectedContainerName = $derived.by(() => {
		console.log('Looking for container with ID:', $formData.container_id);
		console.log(
			'Available containers:',
			hierarchicalContainers.map((c) => ({ id: c.id, name: c.displayName }))
		);
		const container = hierarchicalContainers.find((c) => c.id === $formData.container_id);
		console.log('Found container:', container);
		return container?.displayName || 'Select a container';
	});

	const handleEdit = () => {
		isEditMode = true;

		// Ensure all category attributes are initialized in form data
		if (!$formData.attributes) {
			$formData.attributes = {};
		}

		// Initialize any missing category attributes
		categoryAttributes.forEach((attr) => {
			if (attr.name && !($formData.attributes![attr.name] !== undefined)) {
				$formData.attributes![attr.name] = attr.default_value ?? undefined;
			}
		});
	};

	const handleCancel = () => {
		isEditMode = false;
	};

	function clearAttributeError(attrName: string) {
		if (attributeErrors[attrName]) {
			// eslint-disable-next-line @typescript-eslint/no-unused-vars
			const { [attrName]: _removed, ...rest } = attributeErrors;
			attributeErrors = rest;
		}
	}

	const getItemDisplayName = (item: {
		id: string;
		attributes?: Record<string, unknown> | null;
		category?: { name?: string | null } | null;
	}) => {
		if (item.attributes?.name) return item.attributes.name;
		if (item.attributes?.brand && item.attributes?.type) {
			return `${item.attributes.brand} ${item.attributes.type}`;
		}
		return `${item.category?.name || 'Item'} #${item.id.slice(-8)}`;
	};

	const getActionIcon = (action: string) => {
		switch (action) {
			case 'created':
				return Plus;
			case 'moved':
				return Package;
			case 'updated':
				return Clock;
			default:
				return Clock;
		}
	};

	const getActionColor = (action: string) => {
		switch (action) {
			case 'created':
				return 'text-green-600';
			case 'moved':
				return 'text-blue-600';
			case 'updated':
				return 'text-yellow-600';
			default:
				return 'text-gray-600';
		}
	};
</script>

<div class="p-6 pb-24">
	<div class="mb-6">
		<div class="flex items-center justify-between mb-2">
			<div class="flex items-center gap-2">
				<Button href="/dashboard/inventory/items" variant="ghost" size="sm">
					<ArrowLeft class="h-4 w-4" />
				</Button>
				<h1 class="text-3xl font-bold">{getItemDisplayName(displayItem)}</h1>
				{#if displayItem.out_for_maintenance}
					<Badge variant="destructive" class="flex items-center gap-1">Out for Maintenance</Badge>
				{/if}
			</div>
			{#if canEdit && !isEditMode}
				<Button onclick={handleEdit}>
					<Edit class="mr-2 h-4 w-4" />
					Edit Item
				</Button>
			{/if}
		</div>
		<p class="text-muted-foreground">Item details and history</p>
	</div>

	<form method="POST" use:enhance>
		<!-- Hidden field to preserve category_id since it's not editable -->
		<input type="hidden" name="category_id" bind:value={$formData.category_id} />
		<div class="grid gap-6 lg:grid-cols-3">
			<!-- Item Information -->
			<div class="lg:col-span-2 space-y-6">
				<Card>
					<CardHeader>
						<CardTitle class="flex items-center gap-2">
							<Package class="h-5 w-5" />
							Item Information
						</CardTitle>
					</CardHeader>
					<CardContent class="space-y-4">
						{#if isEditMode}
							<div class="grid gap-4 md:grid-cols-2">
								<!-- Category is read-only in edit mode -->
								<div>
									<h3 class="font-medium text-sm">Category</h3>
									<div class="flex items-center gap-2 mt-1 p-3 bg-muted rounded-md">
										<Tags class="h-4 w-4 text-muted-foreground" />
										<span class="text-sm">{displayItem.category?.name || 'Uncategorized'}</span>
									</div>
									<p class="text-xs text-muted-foreground mt-1">
										Category cannot be changed after creation
									</p>
								</div>

								<Form.Field {form} name="container_id">
									<Form.Control>
										{#snippet children({ props })}
											<Form.Label>Container *</Form.Label>
											<Select type="single" bind:value={$formData.container_id} name={props.name}>
												<SelectTrigger {...props}>
													{selectedContainerName}
												</SelectTrigger>
												<SelectContent>
													{#each hierarchicalContainers as container (container.id)}
														<SelectItem value={container.id}>
															{container.displayName}
														</SelectItem>
													{/each}
												</SelectContent>
											</Select>
										{/snippet}
									</Form.Control>
									<Form.FieldErrors />
								</Form.Field>

								<Form.Field {form} name="quantity">
									<Form.Control>
										{#snippet children({ props })}
											<Form.Label>Quantity *</Form.Label>
											<Input {...props} type="number" min="1" bind:value={$formData.quantity} />
										{/snippet}
									</Form.Control>
									<Form.FieldErrors />
								</Form.Field>

								<Form.Field {form} name="out_for_maintenance">
									<Form.Control>
										{#snippet children({ props })}
											<div class="flex items-center space-x-2 pt-6">
												<Checkbox {...props} bind:checked={$formData.out_for_maintenance} />
												<Form.Label>Out for maintenance</Form.Label>
											</div>
										{/snippet}
									</Form.Control>
									<Form.FieldErrors />
								</Form.Field>
							</div>

							<Form.Field {form} name="notes">
								<Form.Control>
									{#snippet children({ props })}
										<Form.Label>Notes</Form.Label>
										<Textarea
											{...props}
											bind:value={$formData.notes}
											placeholder="Optional notes about this item"
											rows={3}
										/>
									{/snippet}
								</Form.Control>
								<Form.FieldErrors />
							</Form.Field>
						{:else}
							<div class="grid gap-4 md:grid-cols-2">
								<div>
									<h3 class="font-medium">Category</h3>
									<div class="flex items-center gap-2 mt-1">
										<Tags class="h-4 w-4 text-muted-foreground" />
										<span class="text-sm">{displayItem.category?.name || 'Uncategorized'}</span>
									</div>
								</div>

								<div>
									<h3 class="font-medium">Container</h3>
									<div class="flex items-center gap-2 mt-1">
										<FolderOpen class="h-4 w-4 text-muted-foreground" />
										<Button
											href="/dashboard/inventory/containers/{displayItem.container.id}"
											variant="link"
											class="p-0 h-auto text-sm"
										>
											{displayItem.container.name}
										</Button>
									</div>
								</div>

								<div>
									<h3 class="font-medium">Quantity</h3>
									<p class="text-sm text-muted-foreground mt-1">{displayItem.quantity}</p>
								</div>

								<div>
									<h3 class="font-medium">Status</h3>
									<div class="mt-1">
										{#if displayItem.out_for_maintenance}
											<Badge variant="destructive" class="text-xs">Out for Maintenance</Badge>
										{:else}
											<Badge variant="secondary" class="text-xs">Available</Badge>
										{/if}
									</div>
								</div>
							</div>

							{#if displayItem.notes}
								<div>
									<h3 class="font-medium">Notes</h3>
									<p class="text-sm text-muted-foreground mt-1">{displayItem.notes}</p>
								</div>
							{/if}
						{/if}

						<div class="grid gap-4 md:grid-cols-2">
							<div>
								<h3 class="font-medium">Created</h3>
								<p class="text-sm text-muted-foreground mt-1">
									{dayjs(displayItem.created_at).format('MMM D, YYYY [at] h:mm A')}
								</p>
							</div>

							<div>
								<h3 class="font-medium">Last Updated</h3>
								<p class="text-sm text-muted-foreground mt-1">
									{dayjs(displayItem.updated_at).format('MMM D, YYYY [at] h:mm A')}
								</p>
							</div>
						</div>
					</CardContent>
				</Card>

				<!-- Attributes -->
				{#if isEditMode ? categoryAttributes.length > 0 : displayItem.category?.available_attributes && Array.isArray(displayItem.category.available_attributes) && displayItem.category.available_attributes.length > 0}
					<Card>
						<CardHeader>
							<CardTitle>Category Attributes</CardTitle>
							<CardDescription>
								Specific attributes for {displayItem.category?.name} items
							</CardDescription>
						</CardHeader>
						<CardContent>
							{#if isEditMode}
								<!-- Edit Mode -->
								{#if categoryAttributes.length > 0}
									<div class="space-y-4">
										<h3 class="text-lg font-medium">Item Attributes</h3>
										<div class="grid gap-4 md:grid-cols-2">
											{#each categoryAttributes as attr (attr.name)}
												{#if attr.type === 'text' || attr.type === 'number'}
													<div class="space-y-2">
														<Label
															for={attr.name}
															class={attributeErrors[attr.name] ? 'text-destructive' : ''}
														>
															{attr.label}
															{#if attr.required}
																<span class="text-destructive">*</span>
															{/if}
														</Label>
														{#if attr.type === 'text'}
															<Input
																id={attr.name}
																bind:value={$formData.attributes![attr.name]}
																placeholder={attr.label}
																class={attributeErrors[attr.name]
																	? 'border-destructive focus-visible:ring-destructive'
																	: ''}
																oninput={() => clearAttributeError(attr.name)}
																aria-invalid={attributeErrors[attr.name] ? 'true' : undefined}
															/>
														{:else if attr.type === 'number'}
															<Input
																id={attr.name}
																type="number"
																bind:value={$formData.attributes![attr.name]}
																placeholder={attr.label}
																class={attributeErrors[attr.name] ? 'border-destructive' : ''}
																oninput={() => clearAttributeError(attr.name)}
															/>
														{/if}
														{#if attributeErrors[attr.name]}
															<p class="text-sm font-medium text-destructive">
																{attributeErrors[attr.name]}
															</p>
														{/if}
													</div>
												{:else if attr.type === 'select' && attr.options}
													<div class="space-y-2">
														<Label
															for={attr.name}
															class={attributeErrors[attr.name] ? 'text-destructive' : ''}
														>
															{attr.label}
															{#if attr.required}
																<span class="text-destructive">*</span>
															{/if}
														</Label>
														<Select
															type="single"
															value={$formData.attributes![attr.name] || undefined}
															name="attributes.{attr.name}"
															onValueChange={(value) => {
																if (value) {
																	$formData.attributes![attr.name] = value;
																}
																clearAttributeError(attr.name);
															}}
														>
															<SelectTrigger
																class={attributeErrors[attr.name] ? 'border-destructive' : ''}
															>
																{$formData.attributes![attr.name] ||
																	`Select ${attr.label.toLowerCase()}`}
															</SelectTrigger>
															<SelectContent>
																{#each attr.options as option (option)}
																	<SelectItem value={option}>{option}</SelectItem>
																{/each}
															</SelectContent>
														</Select>
														{#if attributeErrors[attr.name]}
															<p class="text-sm font-medium text-destructive">
																{attributeErrors[attr.name]}
															</p>
														{/if}
													</div>
												{:else if attr.type === 'boolean'}
													<div class="space-y-2">
														<Label
															for={attr.name}
															class={attributeErrors[attr.name] ? 'text-destructive' : ''}
														>
															{attr.label}
															{#if attr.required}
																<span class="text-destructive">*</span>
															{/if}
														</Label>
														<div class="flex items-center space-x-2">
															<Checkbox
																id={attr.name}
																name="attributes.{attr.name}"
																bind:checked={$formData.attributes![attr.name]}
																onCheckedChange={() => clearAttributeError(attr.name)}
															/>
															<Label for={attr.name} class="text-sm font-normal">
																{attr.label}
															</Label>
														</div>
														{#if attributeErrors[attr.name]}
															<p class="text-sm font-medium text-destructive">
																{attributeErrors[attr.name]}
															</p>
														{/if}
													</div>
												{/if}
											{/each}
										</div>
									</div>
								{:else}
									<div class="text-center py-8 text-muted-foreground">
										<p>This category has no custom attributes defined.</p>
									</div>
								{/if}
							{:else}
								<!-- View Mode -->
								<div class="grid gap-4 md:grid-cols-2">
									{#if Array.isArray(displayItem.category.available_attributes)}
										{#each displayItem.category.available_attributes as attr (attr.name)}
											{@const attrValue = displayItem.attributes
												? displayItem.attributes[attr.name]
												: undefined}
											<div>
												<h3 class="font-medium">{attr.label || attr.name}</h3>
												<p class="text-sm text-muted-foreground mt-1">
													{#if attrValue !== undefined && attrValue !== null && attrValue !== ''}
														{#if attr.type === 'boolean'}
															{attrValue ? 'Yes' : 'No'}
														{:else}
															{attrValue}
														{/if}
													{:else}
														<span class="italic">Not set</span>
													{/if}
												</p>
											</div>
										{/each}
									{/if}
								</div>
							{/if}
						</CardContent>
					</Card>
				{/if}
			</div>

			<!-- Actions & History -->
			<div class="space-y-6">
				<!-- Actions -->
				{#if !isEditMode}
					<Card>
						<CardHeader>
							<CardTitle>Actions</CardTitle>
						</CardHeader>
						<CardContent class="space-y-3">
							<Button
								href="/dashboard/inventory/containers/{displayItem.container.id}"
								variant="outline"
								class="w-full"
							>
								<FolderOpen class="mr-2 h-4 w-4" />
								View Container
							</Button>
						</CardContent>
					</Card>
				{/if}

				<!-- History -->
				<Card>
					<CardHeader>
						<CardTitle class="flex items-center gap-2">
							<Clock class="h-5 w-5" />
							History
						</CardTitle>
						<CardDescription>Recent changes to this item</CardDescription>
					</CardHeader>
					<CardContent>
						{#if currentHistory.length === 0}
							<p class="text-sm text-muted-foreground">No history available</p>
						{:else}
							<div class="space-y-3">
								{#each currentHistory as entry (entry.id)}
									{@const ActionIcon = getActionIcon(entry.action)}
									<div class="flex items-start gap-3">
										<div class="flex h-8 w-8 items-center justify-center rounded-full bg-muted">
											<ActionIcon class="h-4 w-4 {getActionColor(entry.action)}" />
										</div>
										<div class="flex-1 space-y-1">
											<p class="text-sm">
												<span class="font-medium capitalize">{entry.action}</span>
												{#if entry.action === 'moved' && entry.old_container && entry.new_container}
													from {entry.old_container.name} to {entry.new_container.name}
												{/if}
											</p>
											<p class="text-xs text-muted-foreground">
												{dayjs(entry.created_at).fromNow()}
											</p>
										</div>
									</div>
								{/each}
							</div>
						{/if}
					</CardContent>
				</Card>
			</div>
		</div>

		<!-- Floating Action Bar -->
		{#if isEditMode}
			<div
				class="fixed bottom-0 left-0 right-0 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60 z-50"
			>
				<div class="container flex h-16 items-center justify-between max-w-7xl mx-auto px-6">
					<p class="text-sm text-muted-foreground">Make changes to the item details above</p>
					<div class="flex gap-3">
						<Button type="button" variant="outline" onclick={handleCancel} disabled={$delayed}>
							<X class="mr-2 h-4 w-4" />
							Cancel
						</Button>
						<Button type="submit" disabled={$delayed}>
							{$delayed ? 'Saving...' : 'Save Changes'}
						</Button>
					</div>
				</div>
			</div>
		{/if}
	</form>
</div>
{#if dev}
	<SuperDebug data={$formData} />
{/if}
