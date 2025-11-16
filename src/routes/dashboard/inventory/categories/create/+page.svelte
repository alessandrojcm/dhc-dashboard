<script lang="ts">
import { toast } from "svelte-sonner";
import { superForm } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import { goto } from "$app/navigation";
import { categorySchema } from "$lib/schemas/inventory";

const { data } = $props();

const form = superForm(data.form, {
	validators: valibot(categorySchema),
	resetForm: true,
	dataType: "json",
	onUpdated: ({ form }) => {
		if (form.message?.success) {
			toast.success(form.message.success);
			setTimeout(() => goto("/dashboard/inventory/categories"), 1500);
		}
	},
});

const { form: formData, enhance, submitting } = form;
</script>

<div class="p-6">
	<div class="mb-6">
		<div class="flex items-center gap-2 mb-2">
			<Button href="/dashboard/inventory/categories" variant="ghost" size="sm">
				<ArrowLeft class="h-4 w-4" />
			</Button>
			<h1 class="text-3xl font-bold">Create Equipment Category</h1>
		</div>
		<p class="text-muted-foreground">Define a new equipment category with custom attributes</p>
	</div>

	<form method="POST" use:enhance class="space-y-6">
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
					Define the attributes that items in this category will have. For example, masks might have
					attributes like "brand", "size", and "color".
				</CardDescription>
			</CardHeader>
			<CardContent>
				<AttributeBuilder {form} />
			</CardContent>
		</Card>

		<!-- Actions -->
		<div class="flex gap-3">
			<Form.Button type="submit" disabled={$submitting}>
				{$submitting ? 'Creating...' : 'Create Category'}
			</Form.Button>
			<Button href="/dashboard/inventory/categories" variant="outline">Cancel</Button>
		</div>
	</form>
	{#if import.meta.env.DEV}
		<SuperDebug data={$formData} />
	{/if}
</div>
