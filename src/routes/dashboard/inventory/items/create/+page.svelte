<script lang="ts">
	import { superForm } from 'sveltekit-superforms';
	import { valibot } from 'sveltekit-superforms/adapters';
	import { itemSchema } from '$lib/schemas/inventory';
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
	import { ArrowLeft, Package } from 'lucide-svelte';
	import DynamicAttributeFields from '$lib/components/inventory/DynamicAttributeFields.svelte';

	let { data } = $props();

	const form = superForm(data.form, {
		validators: valibot(itemSchema),
		resetForm: true,
		dataType: 'json'
	});

	const { form: formData, enhance, submitting } = form;

	// Reactive category selection for dynamic attributes
	let selectedCategory = $derived(data.categories.find((c) => c.id === $formData.category_id));

	// Build hierarchy display for container selection
	const buildHierarchyDisplay = (containers: any[]) => {
		const containerMap = new Map();
		const rootContainers: any[] = [];

		containers.forEach((container) => {
			containerMap.set(container.id, { ...container, children: [] });
		});

		containers.forEach((container) => {
			if (container.parent_container_id) {
				const parent = containerMap.get(container.parent_container_id);
				if (parent) {
					parent.children.push(containerMap.get(container.id));
				}
			} else {
				rootContainers.push(containerMap.get(container.id));
			}
		});

		const flattenWithIndent = (containers: any[], level = 0): any[] => {
			const result: any[] = [];
			containers.forEach((container) => {
				result.push({
					...container,
					displayName: '  '.repeat(level) + container.name,
					level
				});
				if (container.children.length > 0) {
					result.push(...flattenWithIndent(container.children, level + 1));
				}
			});
			return result;
		};

		return flattenWithIndent(rootContainers);
	};

	const hierarchicalContainers = buildHierarchyDisplay(data.containers);
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
								<Select name={props.name} type="single" bind:value={$formData.category_id}>
									<SelectTrigger {...props}>
										{$formData.category_id}
									</SelectTrigger>
									<SelectContent>
										{#each data.categories as category}
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
										{$formData.container_id}
									</SelectTrigger>
									<SelectContent>
										{#each hierarchicalContainers as container}
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
					<DynamicAttributeFields
						category={selectedCategory}
						bind:attributes={$formData.attributes}
						{form}
					/>
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
