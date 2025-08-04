<script lang="ts">
	import { superForm } from 'sveltekit-superforms';
	import { valibot } from 'sveltekit-superforms/adapters';
	import { itemSchema } from '$lib/schemas/inventory';
	import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import { ArrowLeft, Package } from 'lucide-svelte';
	import DynamicAttributeFields from '$lib/components/inventory/DynamicAttributeFields.svelte';

	let { data } = $props();

	const { form, errors, enhance, submitting } = superForm(data.form, {
		validators: valibot(itemSchema),
		resetForm: true,
		dataType: 'json'
	});

	// Initialize attributes if not set
	if (!$form.attributes) {
		$form.attributes = {};
	}

	// Reactive category selection for dynamic attributes
	let selectedCategory = $derived(
		data.categories.find(c => c.id === $form.category_id)
	);

	// Build hierarchy display for container selection
	const buildHierarchyDisplay = (containers: any[]) => {
		const containerMap = new Map();
		const rootContainers: any[] = [];

		containers.forEach(container => {
			containerMap.set(container.id, { ...container, children: [] });
		});

		containers.forEach(container => {
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
			containers.forEach(container => {
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
				<CardDescription>
					Basic details about the equipment item
				</CardDescription>
			</CardHeader>
			<CardContent class="space-y-4">
				<div class="grid gap-4 md:grid-cols-2">
					<div class="space-y-2">
						<Label for="category_id">Category *</Label>
						<Select type="single" bind:value={$form.category_id} name="category_id">
							<SelectTrigger class={$errors.category_id ? 'border-destructive' : ''}>
								{$form.category_id}
							</SelectTrigger>
							<SelectContent>
								{#each data.categories as category}
									<SelectItem value={category.id}>{category.name}</SelectItem>
								{/each}
							</SelectContent>
						</Select>
						{#if $errors.category_id}
							<p class="text-sm text-destructive">{$errors.category_id}</p>
						{/if}
					</div>

					<div class="space-y-2">
						<Label for="container_id">Container *</Label>
						<Select type="single" bind:value={$form.container_id} name="container_id">
							<SelectTrigger class={$errors.container_id ? 'border-destructive' : ''}>
								{$form.container_id}
							</SelectTrigger>
							<SelectContent>
								{#each hierarchicalContainers as container}
									<SelectItem value={container.id}>
										{container.displayName}
									</SelectItem>
								{/each}
							</SelectContent>
						</Select>
						{#if $errors.container_id}
							<p class="text-sm text-destructive">{$errors.container_id}</p>
						{/if}
					</div>
				</div>

				<div class="grid gap-4 md:grid-cols-2">
					<div class="space-y-2">
						<Label for="quantity">Quantity *</Label>
						<Input
							id="quantity"
							name="quantity"
							type="number"
							min="1"
							bind:value={$form.quantity}
							class={$errors.quantity ? 'border-destructive' : ''}
						/>
						{#if $errors.quantity}
							<p class="text-sm text-destructive">{$errors.quantity}</p>
						{/if}
					</div>

					<div class="flex items-center space-x-2 pt-6">
						<Checkbox 
							id="out_for_maintenance"
							name="out_for_maintenance"
							bind:checked={$form.out_for_maintenance}
						/>
						<Label for="out_for_maintenance">Out for maintenance</Label>
					</div>
				</div>

				<div class="space-y-2">
					<Label for="notes">Notes</Label>
					<Textarea
						id="notes"
						name="notes"
						bind:value={$form.notes}
						placeholder="Optional notes about this item"
						rows={3}
						class={$errors.notes ? 'border-destructive' : ''}
					/>
					{#if $errors.notes}
						<p class="text-sm text-destructive">{$errors.notes}</p>
					{/if}
				</div>
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
						bind:attributes={$form.attributes} 
						errors={$errors} 
					/>
				</CardContent>
			</Card>
		{/if}

		<!-- Actions -->
		<div class="flex gap-3">
			<Button type="submit" disabled={$submitting}>
				{$submitting ? 'Creating...' : 'Create Item'}
			</Button>
			<Button href="/dashboard/inventory/items" variant="outline">
				Cancel
			</Button>
		</div>
	</form>
</div>
