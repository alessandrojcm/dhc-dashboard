<script lang="ts">
	import { superForm } from 'sveltekit-superforms';
	import { valibot } from 'sveltekit-superforms/adapters';
	import { categorySchema } from '$lib/schemas/inventory';
	import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Textarea } from '$lib/components/ui/textarea';
	import * as Form from '$lib/components/ui/form';
	import { ArrowLeft, Tags, Trash2 } from 'lucide-svelte';
	import { enhance } from '$app/forms';
	import AttributeBuilder from '$lib/components/inventory/AttributeBuilder.svelte';
	import { toast } from 'svelte-sonner';
	import { goto } from '$app/navigation';

	let { data } = $props();

	const form = superForm(data.form, {
		validators: valibot(categorySchema),
		dataType: 'json',
		onUpdated: ({ form }) => {
			if (form.message?.success) {
				toast.success(form.message.success);
				setTimeout(() => goto('/dashboard/inventory/categories'), 1500);
			}
		}
	});

	const { form: formData, enhance: formEnhance, submitting } = form;

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

	<form method="POST" action="?/update" use:formEnhance class="space-y-6">
		<!-- Basic Information -->
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					<Tags class="h-5 w-5" />
					Category Information
				</CardTitle>
				<CardDescription>
					Basic details about the equipment category
				</CardDescription>
			</CardHeader>
			<CardContent class="space-y-4">
				<Form.Field {form} name="name">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Category Name *</Form.Label>
							<Input
								{...props}
								bind:value={$formData.name}
								placeholder="e.g., Masks, Jackets, Swords"
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>

				<Form.Field {form} name="description">
					<Form.Control>
						{#snippet children({ props })}
							<Form.Label>Description</Form.Label>
							<Textarea
								{...props}
								bind:value={$formData.description}
								placeholder="Optional description of this equipment category"
								rows={3}
							/>
						{/snippet}
					</Form.Control>
					<Form.FieldErrors />
				</Form.Field>
			</CardContent>
		</Card>

		<!-- Attribute Builder -->
		<Card>
			<CardHeader>
				<CardTitle>Custom Attributes</CardTitle>
				<CardDescription>
					Define the attributes that items in this category will have. Be careful when removing attributes as it may affect existing items.
				</CardDescription>
			</CardHeader>
			<CardContent>
				<AttributeBuilder {form} />
			</CardContent>
		</Card>

		<!-- Actions -->
		<div class="flex gap-3">
			<Form.Button type="submit" disabled={$submitting}>
				{$submitting ? 'Updating...' : 'Update Category'}
			</Form.Button>
			<Button href="/dashboard/inventory/categories" variant="outline">
				Cancel
			</Button>
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
				Permanently delete this category. This action cannot be undone and will affect all items in this category.
			</CardDescription>
		</CardHeader>
		<CardContent>
			{#if !showDeleteConfirm}
				<Button 
					variant="destructive" 
					onclick={() => showDeleteConfirm = true}
				>
					Delete Category
				</Button>
			{:else}
				<div class="space-y-4">
					<p class="text-sm text-muted-foreground">
						Are you sure you want to delete this category? This will also delete all items in this category. This action cannot be undone.
					</p>
					<div class="flex gap-3">
						<form method="POST" action="?/delete" use:enhance>
							<Button type="submit" variant="destructive">
								Yes, Delete Category
							</Button>
						</form>
						<Button 
							variant="outline" 
							onclick={() => showDeleteConfirm = false}
						>
							Cancel
						</Button>
					</div>
				</div>
			{/if}
		</CardContent>
	</Card>
</div>