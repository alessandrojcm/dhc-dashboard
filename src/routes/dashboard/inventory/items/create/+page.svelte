<script lang="ts">
	import SuperDebug, { superForm } from 'sveltekit-superforms';
	import { valibot } from 'sveltekit-superforms/adapters';
	import { itemSchema } from '$lib/schemas/inventory';
	import type { InventoryCategory, InventoryAttributeDefinition } from '$lib/types';
	import {
		Card,
		CardContent,
		CardDescription,
		CardHeader,
		CardTitle
	} from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import * as Form from '$lib/components/ui/form';
	import { ArrowLeft, Package, AlertCircle } from 'lucide-svelte';
	import { dev } from '$app/environment';
	import { Label } from '$lib/components/ui/label';
	import { Alert, AlertDescription } from '$lib/components/ui/alert';
	import { buildContainerHierarchy } from '$lib/utils/inventory-form';

	let { data } = $props();

	// Track validation errors for attributes
	let attributeErrors = $state<Record<string, string>>({});

	const form = superForm(data.form, {
		validators: valibot(itemSchema),
		resetForm: true,
		dataType: 'json',
		onSubmit: ({ formData: submitData, cancel }) => {
			// Validate required attributes
			const newErrors: Record<string, string> = {};
			let hasErrors = false;

			if (selectedCategory) {
				const attributes =
					(selectedCategory.available_attributes as InventoryAttributeDefinition[]) || [];
				attributes.forEach((attr) => {
					if (attr.required) {
						const value = $formData.attributes?.[attr.name];
						if (!value || value === '' || value === null || value === undefined) {
							newErrors[attr.name] = `${attr.label} is required`;
							hasErrors = true;
						}
					}
				});
			}

			attributeErrors = newErrors;

			if (hasErrors) {
				cancel();
				return;
			}

			// Clean attributes to only include non-empty values
			const attributesRaw = submitData.get('attributes');
			const attributes = attributesRaw ? JSON.parse(attributesRaw as string) : {};
			const cleanedAttributes: Record<string, unknown> = {};

			Object.entries(attributes).forEach(([key, value]) => {
				// Only include attributes that have actual values (not null, undefined, or empty string)
				if (value !== null && value !== undefined && value !== '') {
					cleanedAttributes[key] = value;
				}
			});

			submitData.set('attributes', JSON.stringify(cleanedAttributes));
		}
	});

	const { form: formData, enhance, submitting, message } = form;

	const hierarchicalContainers = buildContainerHierarchy(data.containers);

	// Reactive category selection for dynamic attributes
	const selectedCategory = $derived(
		data.categories.find((c) => c.id === $formData.category_id) as InventoryCategory | undefined
	);
	const categoryAttributes = $derived(
		(selectedCategory?.available_attributes as InventoryAttributeDefinition[]) || []
	);

	// Display names for selected items
	const selectedCategoryName = $derived(selectedCategory?.name || 'Select a category');
	const selectedContainerName = $derived.by(() => {
		const container = hierarchicalContainers.find((c) => c.id === $formData.container_id);
		return container?.displayName || 'Select a container';
	});

	function updateCategory(categoryId: string) {
		$formData.category_id = categoryId;

		// Clear attribute errors
		attributeErrors = {};

		// Reset attributes when category changes
		$formData.attributes = {};

		// Find the selected category
		const category = data.categories.find((c) => c.id === categoryId);
		if (!category) return;

		// Initialize only required attributes or those with default values
		const attributes = (category.available_attributes as InventoryAttributeDefinition[]) || [];
		attributes.forEach((attr) => {
			// Only set default value if explicitly provided, don't initialize with null
			if (attr.default_value !== undefined && $formData.attributes) {
				$formData.attributes[attr.name] = attr.default_value;
			}
		});
	}

	function clearAttributeError(attrName: string) {
		if (attributeErrors[attrName]) {
			// eslint-disable-next-line @typescript-eslint/no-unused-vars
			const { [attrName]: _removed, ...rest } = attributeErrors;
			attributeErrors = rest;
		}
	}
</script>

<div class="p-6">
	<div class="mb-6">
		<div class="flex items-center gap-2 mb-2">
			<Button href="/dashboard/inventory/items" variant="ghost" size="sm">
				<ArrowLeft class="h-4 w-4" />
			</Button>
			<h1 class="text-3xl font-bold">Add New Item</h1>
		</div>
		<p class="text-muted-foreground">Add a new equipment item to your inventory</p>
	</div>

	<!-- Error message display -->
	{#if $message}
		<Alert variant="destructive">
			<AlertCircle class="h-4 w-4" />
			<AlertDescription>{$message}</AlertDescription>
		</Alert>
	{/if}

	<form method="POST" use:enhance class="space-y-6">
		<!-- Basic Information -->
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					<Package class="h-5 w-5" />
					Item Information
				</CardTitle>
				<CardDescription>Basic details about the equipment item</CardDescription>
			</CardHeader>
			<CardContent class="space-y-4">
				<div class="grid gap-4 md:grid-cols-2">
					<Form.Field {form} name="category_id">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label>Category *</Form.Label>
								<Select name={props.name} type="single" onValueChange={updateCategory}>
									<SelectTrigger {...props}>
										{selectedCategoryName}
									</SelectTrigger>
									<SelectContent>
										{#each data.categories as category (category.id)}
											<SelectItem value={category.id}>{category.name}</SelectItem>
										{/each}
									</SelectContent>
								</Select>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

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
				</div>

				<div class="grid gap-4 md:grid-cols-2">
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
			</CardContent>
		</Card>

		<!-- Dynamic Attributes -->
		{#if selectedCategory}
			<Card>
				<CardHeader>
					<CardTitle>Category Attributes</CardTitle>
					<CardDescription>
						Specific attributes for {selectedCategory.name} items
					</CardDescription>
				</CardHeader>
				<CardContent>
					{#if categoryAttributes.length > 0}
						<div class="space-y-4">
							<h3 class="text-lg font-medium">Item Attributes</h3>
							<div class="grid gap-4 md:grid-cols-2">
								{#each categoryAttributes as attr (attr.name)}
									{#if attr.name}
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
													bind:value={$formData.attributes[attr.name]}
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
													bind:value={$formData.attributes[attr.name]}
													placeholder={attr.label}
													class={attributeErrors[attr.name] ? 'border-destructive' : ''}
													oninput={() => clearAttributeError(attr.name)}
												/>
											{:else if attr.type === 'select' && attr.options}
												<Select
													type="single"
													value={$formData.attributes?.[attr.name] || undefined}
													name="attributes.{attr.name}"
													onValueChange={(value) => {
														if (value && $formData.attributes) {
															$formData.attributes[attr.name] = value;
														}
														clearAttributeError(attr.name);
													}}
												>
													<SelectTrigger
														class={attributeErrors[attr.name] ? 'border-destructive' : ''}
													>
														{$formData.attributes?.[attr.name] ||
															`Select ${attr.label.toLowerCase()}`}
													</SelectTrigger>
													<SelectContent>
														{#each attr.options as option (option)}
															<SelectItem value={option}>{option}</SelectItem>
														{/each}
													</SelectContent>
												</Select>
											{:else if attr.type === 'boolean'}
												<div class="flex items-center space-x-2">
													<Checkbox
														id={attr.name}
														name="attributes.{attr.name}"
														bind:checked={$formData.attributes[attr.name]}
														onCheckedChange={() => clearAttributeError(attr.name)}
													/>
													<Label for={attr.name} class="text-sm font-normal">
														{attr.label}
													</Label>
												</div>
											{/if}
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
				</CardContent>
			</Card>
		{/if}

		<!-- Actions -->
		<div class="flex gap-3">
			<Button type="submit" disabled={$submitting}>
				{$submitting ? 'Creating...' : 'Create Item'}
			</Button>
			<Button href="/dashboard/inventory/items" variant="outline">Cancel</Button>
		</div>
	</form>
</div>
{#if dev}
	<SuperDebug data={$formData} />
{/if}
