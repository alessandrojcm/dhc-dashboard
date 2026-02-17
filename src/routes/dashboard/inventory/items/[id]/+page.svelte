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
	import * as Field from '$lib/components/ui/field';
	import { Input } from '$lib/components/ui/input';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { Label } from '$lib/components/ui/label';
	import { toast } from 'svelte-sonner';
	import { ArrowLeft, Package, Edit, X, FolderOpen, Tags, Clock, Plus } from 'lucide-svelte';
	import dayjs from 'dayjs';
	import relativeTime from 'dayjs/plugin/relativeTime';
	import { buildContainerHierarchy } from '$lib/utils/inventory-form';
	import { updateItem } from '../data.remote';
	import { onMount } from 'svelte';
	import type { InventoryAttributeDefinition } from '$lib/types';

	dayjs.extend(relativeTime);
	let { data } = $props();
	const { item: initialItem, containers, canEdit } = data;

	// Track the current item state (will be updated after successful edits)
	let currentItem = $state(initialItem);

	// Make history reactive so it updates after invalidateAll
	const currentHistory = $derived(data.history);

	let isEditMode = $state(false);
	let attributeErrors = $state<Record<string, string>>({});

	// Local state for form fields
	let containerId = $state(data.initialFormData.container_id);
	let quantity = $state(data.initialFormData.quantity);
	let notes = $state(data.initialFormData.notes);
	let outForMaintenance = $state(data.initialFormData.out_for_maintenance);
	let attributes = $state<Record<string, unknown>>(data.initialFormData.attributes);

	onMount(() => {
		updateItem.fields.set({
			container_id: data.initialFormData.container_id,
			category_id: data.initialFormData.category_id,
			quantity: data.initialFormData.quantity,
			notes: data.initialFormData.notes,
			out_for_maintenance: data.initialFormData.out_for_maintenance,
			attributes: data.initialFormData.attributes
		});
	});

	// Handle success from form submission
	$effect(() => {
		const result = updateItem.result;
		if (result?.success) {
			toast.success(result.success, { position: 'top-right' });
			isEditMode = false;
		}
	});

	// Use current item for display
	const displayItem = $derived(currentItem);
	const hierarchicalContainers = buildContainerHierarchy(containers);

	// Use the display item's category since it can't be changed
	const categoryAttributes = $derived(
		(displayItem.category?.available_attributes as InventoryAttributeDefinition[]) || []
	);
	const selectedContainerName = $derived.by(() => {
		const container = hierarchicalContainers.find((c) => c.id === containerId);
		return container?.displayName || 'Select a container';
	});

	const handleEdit = () => {
		isEditMode = true;

		// Initialize any missing category attributes
		categoryAttributes.forEach((attr) => {
			if (attr.name && attributes[attr.name] === undefined) {
				attributes[attr.name] = attr.default_value ?? undefined;
			}
		});
		updateItem.fields.attributes.set({ ...attributes });
	};

	const handleCancel = () => {
		isEditMode = false;
		// Reset to original values
		containerId = data.initialFormData.container_id;
		quantity = data.initialFormData.quantity;
		notes = data.initialFormData.notes;
		outForMaintenance = data.initialFormData.out_for_maintenance;
		attributes = { ...data.initialFormData.attributes };
	};

	function updateAttribute(attrName: string, value: unknown) {
		attributes[attrName] = value;
		updateItem.fields.attributes.set({ ...attributes });
		clearAttributeError(attrName);
	}

	function clearAttributeError(attrName: string) {
		if (attributeErrors[attrName]) {
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

	<form {...updateItem}>
		<!-- Hidden field to preserve category_id since it's not editable -->
		<input type="hidden" name="category_id" value={data.initialFormData.category_id} />
		<!-- Hidden field for attributes JSON -->
		<input type="hidden" name="attributes" value={JSON.stringify(attributes)} />

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

								<Field.Field>
									<Field.Label>Container *</Field.Label>
									<Select
										type="single"
										value={containerId}
										onValueChange={(v) => {
											containerId = v;
											updateItem.fields.container_id.set(v);
										}}
										name="container_id"
									>
										<SelectTrigger>
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
									{#each updateItem.fields.container_id.issues() as issue}
										<Field.Error>{issue.message}</Field.Error>
									{/each}
								</Field.Field>

								<Field.Field>
									<Field.Label>Quantity *</Field.Label>
									<Input
										type="number"
										min="1"
										name="quantity"
										value={quantity}
										oninput={(e) => {
											quantity = parseInt(e.currentTarget.value) || 1;
											updateItem.fields.quantity.set(quantity);
										}}
									/>
									{#each updateItem.fields.quantity.issues() as issue}
										<Field.Error>{issue.message}</Field.Error>
									{/each}
								</Field.Field>

								<Field.Field>
									<div class="flex items-center space-x-2 pt-6">
										<Checkbox
											name="out_for_maintenance"
											checked={outForMaintenance}
											onCheckedChange={(checked) => {
												outForMaintenance = !!checked;
												updateItem.fields.out_for_maintenance.set(outForMaintenance);
											}}
										/>
										<Label>Out for maintenance</Label>
									</div>
								</Field.Field>
							</div>

							<Field.Field>
								<Field.Label>Notes</Field.Label>
								<Textarea
									name="notes"
									value={notes}
									oninput={(e) => {
										notes = e.currentTarget.value;
										updateItem.fields.notes.set(notes);
									}}
									placeholder="Optional notes about this item"
									rows={3}
								/>
								{#each updateItem.fields.notes.issues() as issue}
									<Field.Error>{issue.message}</Field.Error>
								{/each}
							</Field.Field>
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
																value={attributes[attr.name] as string || ''}
																placeholder={attr.label}
																class={attributeErrors[attr.name]
																	? 'border-destructive focus-visible:ring-destructive'
																	: ''}
																oninput={(e) => updateAttribute(attr.name, e.currentTarget.value)}
																aria-invalid={attributeErrors[attr.name] ? 'true' : undefined}
															/>
														{:else if attr.type === 'number'}
															<Input
																id={attr.name}
																type="number"
																value={attributes[attr.name] as number || ''}
																placeholder={attr.label}
																class={attributeErrors[attr.name] ? 'border-destructive' : ''}
																oninput={(e) => updateAttribute(attr.name, parseFloat(e.currentTarget.value))}
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
															value={attributes[attr.name] as string || undefined}
															name="attributes.{attr.name}"
															onValueChange={(value) => updateAttribute(attr.name, value)}
														>
															<SelectTrigger
																class={attributeErrors[attr.name] ? 'border-destructive' : ''}
															>
																{attributes[attr.name] || `Select ${attr.label.toLowerCase()}`}
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
																checked={!!attributes[attr.name]}
																onCheckedChange={(checked) => updateAttribute(attr.name, !!checked)}
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
						<Button type="button" variant="outline" onclick={handleCancel} disabled={!!updateItem.pending}>
							<X class="mr-2 h-4 w-4" />
							Cancel
						</Button>
						<Button type="submit" disabled={!!updateItem.pending}>
							{updateItem.pending ? 'Saving...' : 'Save Changes'}
						</Button>
					</div>
				</div>
			</div>
		{/if}
	</form>
</div>
