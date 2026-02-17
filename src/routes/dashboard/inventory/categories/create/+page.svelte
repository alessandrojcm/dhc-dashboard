<script lang="ts">
import { createCategory } from "../data.remote";
import {
	Card,
	CardContent,
	CardDescription,
	CardHeader,
	CardTitle,
} from "$lib/components/ui/card";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Textarea } from "$lib/components/ui/textarea";
import * as Field from "$lib/components/ui/field";
import { ArrowLeft, Tags } from "lucide-svelte";
import AttributeBuilder from "$lib/components/inventory/AttributeBuilder.svelte";
import { onMount } from "svelte";
import type { AttributeDefinition } from "$lib/schemas/inventory";

onMount(() => {
	createCategory.fields.set({
		name: "",
		description: "",
		available_attributes: [],
	});
});

// Get current attributes value reactively
const attributes = $derived(
	(createCategory.fields.available_attributes.value() as
		| AttributeDefinition[]
		| undefined) ?? [],
);

// Callback to update attributes
const handleAttributesChange = (newAttributes: AttributeDefinition[]) => {
	createCategory.fields.available_attributes.set(newAttributes);
};
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

	<form {...createCategory} class="space-y-6">
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
					{@const fieldProps = createCategory.fields.name.as('text')}
					<Field.Label for={fieldProps.name}>Category Name *</Field.Label>
					<Input
						{...fieldProps}
						id={fieldProps.name}
						placeholder="e.g., Masks, Jackets, Swords"
					/>
					{#each createCategory.fields.name.issues() as issue}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>

				<Field.Field>
					{@const fieldProps = createCategory.fields.description.as('text')}
					<Field.Label for={fieldProps.name}>Description</Field.Label>
					<Textarea
						{...fieldProps}
						id={fieldProps.name}
						placeholder="Optional description of this equipment category"
						rows={3}
					/>
					{#each createCategory.fields.description.issues() as issue}
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
					Define the attributes that items in this category will have. For example, masks might have
					attributes like "brand", "size", and "color".
				</CardDescription>
			</CardHeader>
			<CardContent>
				<AttributeBuilder
					attributes={attributes}
					onAttributesChange={handleAttributesChange}
					issues={createCategory.fields.available_attributes.issues()}
				/>
			</CardContent>
		</Card>

		<!-- Actions -->
		<div class="flex gap-3">
			<Button type="submit">Create Category</Button>
			<Button href="/dashboard/inventory/categories" variant="outline">Cancel</Button>
		</div>
	</form>
</div>
