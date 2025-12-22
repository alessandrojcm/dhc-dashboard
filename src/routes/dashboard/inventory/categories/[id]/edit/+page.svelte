<script lang="ts">
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
	import * as Field from '$lib/components/ui/field';
	import { ArrowLeft, Tags, Trash2 } from 'lucide-svelte';
	import AttributeBuilder from '$lib/components/inventory/AttributeBuilder.svelte';
	import { updateCategory, deleteCategory } from '../../data.remote';
	import { onMount } from 'svelte';
	import type { AttributeDefinition } from '$lib/schemas/inventory';

	let { data } = $props();

	onMount(() => {
		updateCategory.fields.set({
			name: data.category.name,
			description: data.category.description ?? undefined,
			available_attributes: data.category.available_attributes as AttributeDefinition[]
		});
	});

	// Get current attributes value reactively
	const attributes = $derived(
		(updateCategory.fields.available_attributes.value() as AttributeDefinition[] | undefined) ??
			(data.category.available_attributes as AttributeDefinition[])
	);

	// Callback to update attributes
	const handleAttributesChange = (newAttributes: AttributeDefinition[]) => {
		updateCategory.fields.available_attributes.set(newAttributes);
	};

	let showDeleteConfirm = $state(false);
</script>

<div class="p-6">
	<div class="mb-6">
		<div class="flex items-center gap-2 mb-2">
			<Button href="/dashboard/inventory/categories" variant="ghost" size="sm">
				<ArrowLeft class="h-4 w-4" />
			</Button>
			<h1 class="text-3xl font-bold">Edit Category</h1>
		</div>
		<p class="text-muted-foreground">Update category information and attributes</p>
	</div>

	<form {...updateCategory} class="space-y-6">
		<!-- Basic Information -->
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					<Tags class="h-5 w-5" />
					Category Information
				</CardTitle>
				<CardDescription>Basic details about the equipment category</CardDescription>
			</CardHeader>
			<CardContent class="space-y-4">
				<Field.Field>
					{@const fieldProps = updateCategory.fields.name.as('text')}
					<Field.Label for={fieldProps.name}>Category Name *</Field.Label>
					<Input
						{...fieldProps}
						id={fieldProps.name}
						placeholder="e.g., Masks, Jackets, Swords"
					/>
					{#each updateCategory.fields.name.issues() as issue}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>

				<Field.Field>
					{@const fieldProps = updateCategory.fields.description.as('text')}
					<Field.Label for={fieldProps.name}>Description</Field.Label>
					<Textarea
						{...fieldProps}
						id={fieldProps.name}
						placeholder="Optional description of this equipment category"
						rows={3}
					/>
					{#each updateCategory.fields.description.issues() as issue}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</CardContent>
		</Card>

		<!-- Attribute Builder -->
		<Card>
			<CardHeader>
				<CardTitle>Custom Attributes</CardTitle>
				<CardDescription>
					Define the attributes that items in this category will have. Be careful when removing
					attributes as it may affect existing items.
				</CardDescription>
			</CardHeader>
			<CardContent>
				<AttributeBuilder
					attributes={attributes}
					onAttributesChange={handleAttributesChange}
					issues={updateCategory.fields.available_attributes.issues()}
				/>
			</CardContent>
		</Card>

		<!-- Actions -->
		<div class="flex gap-3">
			<Button type="submit" disabled={!!updateCategory.pending}>
				{updateCategory.pending ? 'Updating...' : 'Update Category'}
			</Button>
			<Button href="/dashboard/inventory/categories" variant="outline">Cancel</Button>
		</div>
	</form>

	<!-- Delete Section -->
	<Card class="mt-6 border-destructive">
		<CardHeader>
			<CardTitle class="text-destructive flex items-center gap-2">
				<Trash2 class="h-5 w-5" />
				Danger Zone
			</CardTitle>
			<CardDescription>
				Permanently delete this category. This action cannot be undone and will affect all items in
				this category.
			</CardDescription>
		</CardHeader>
		<CardContent>
			{#if !showDeleteConfirm}
				<Button variant="destructive" onclick={() => (showDeleteConfirm = true)}>
					Delete Category
				</Button>
			{:else}
				<div class="space-y-4">
					<p class="text-sm text-muted-foreground">
						Are you sure you want to delete this category? This will also delete all items in this
						category. This action cannot be undone.
					</p>
					<div class="flex gap-3">
						<form {...deleteCategory}>
							<Button type="submit" variant="destructive" disabled={!!deleteCategory.pending}>
								{deleteCategory.pending ? 'Deleting...' : 'Yes, Delete Category'}
							</Button>
						</form>
						<Button variant="outline" onclick={() => (showDeleteConfirm = false)}>Cancel</Button>
					</div>
				</div>
			{/if}
		</CardContent>
	</Card>
</div>
