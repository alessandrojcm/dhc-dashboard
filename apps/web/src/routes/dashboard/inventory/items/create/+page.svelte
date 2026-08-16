<script lang="ts">
import type {
	InventoryAttributeDefinition,
	InventoryAttributes,
	InventoryAttributeValue,
} from "$lib/types";
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
import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
} from "$lib/components/ui/select";
import { Checkbox } from "$lib/components/ui/checkbox";
import * as Field from "$lib/components/ui/field";
import { ArrowLeft, Package, AlertCircle } from "@lucide/svelte";
import { Label } from "$lib/components/ui/label";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { buildContainerHierarchy } from "$lib/utils/inventory-form";
import { createItem } from "../data.remote";
import { onMount, untrack } from "svelte";

let { data } = $props();

// Track validation errors for attributes
let attributeErrors = $state<Record<string, string>>({});
let formError = $state<string | null>(null);

// Local state for attributes (since they're dynamic)
let attributes = $state<InventoryAttributes>({});
let categoryId = $state(untrack(() => data.initialData.category_id));
let containerId = $state(untrack(() => data.initialData.container_id));
let quantity = $state(untrack(() => data.initialData.quantity));
let notes = $state(untrack(() => data.initialData.notes));
let outForMaintenance = $state(
	untrack(() => data.initialData.out_for_maintenance),
);

onMount(() => {
	createItem.fields.set({
		container_id: data.initialData.container_id,
		category_id: data.initialData.category_id,
		attributes: JSON.stringify(data.initialData.attributes),
		quantity: data.initialData.quantity,
		notes: data.initialData.notes,
		out_for_maintenance: data.initialData.out_for_maintenance,
	});
});

const hierarchicalContainers = $derived(
	buildContainerHierarchy(data.containers),
);

// Reactive category selection for dynamic attributes
const selectedCategory = $derived(
	data.categories.find((c) => c.id === categoryId),
);
const categoryAttributes = $derived(
	selectedCategory?.available_attributes ?? [],
);

// Display names for selected items
const selectedCategoryName = $derived(
	selectedCategory?.name || "Select a category",
);
const selectedContainerName = $derived.by(() => {
	const container = hierarchicalContainers.find((c) => c.id === containerId);
	return container?.displayName || "Select a container";
});

function updateCategory(newCategoryId: string) {
	categoryId = newCategoryId;
	createItem.fields.category_id.set(newCategoryId);

	// Clear attribute errors
	attributeErrors = {};

	// Reset attributes when category changes
	attributes = {};
	createItem.fields.attributes.set("{}");

	// Find the selected category
	const category = data.categories.find((c) => c.id === newCategoryId);
	if (!category) return;

	// Initialize only required attributes or those with default values
	const availableAttrs: InventoryAttributeDefinition[] =
		category.available_attributes;
	availableAttrs.forEach((attr) => {
		// Only set default value if explicitly provided
		if (attr.default_value !== undefined) {
			attributes[attr.name] = attr.default_value;
		}
	});
	createItem.fields.attributes.set(JSON.stringify(attributes));
}

function updateContainer(newContainerId: string) {
	containerId = newContainerId;
	createItem.fields.container_id.set(newContainerId);
}

function updateAttribute(attrName: string, value: InventoryAttributeValue) {
	attributes[attrName] = value;
	createItem.fields.attributes.set(JSON.stringify(attributes));
	clearAttributeError(attrName);
}

function attributeText(attrName: string): string {
	const value = attributes[attrName];
	return value === null || value === undefined ? "" : String(value);
}

function attributeNumber(attrName: string): number | "" {
	const value = attributes[attrName];
	if (value === null || value === undefined || value === "") return "";
	const parsed = Number(value);
	return Number.isFinite(parsed) ? parsed : "";
}

function clearAttributeError(attrName: string) {
	if (attributeErrors[attrName]) {
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
		<p class="text-muted-foreground">
			Add a new equipment item to your inventory
		</p>
	</div>

	<!-- Error message display -->
	{#if formError}
		<Alert variant="destructive" class="mb-4">
			<AlertCircle class="h-4 w-4" />
			<AlertDescription>{formError}</AlertDescription>
		</Alert>
	{/if}

	<form {...createItem} class="space-y-6">
		<!-- Basic Information -->
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					<Package class="h-5 w-5" />
					Item Information
				</CardTitle>
				<CardDescription>Basic details about the equipment item</CardDescription
				>
			</CardHeader>
			<CardContent class="space-y-4">
				<div class="grid gap-4 md:grid-cols-2">
					<Field.Field>
						<Field.Label>Category *</Field.Label>
						<Select
							type="single"
							name="category_id"
							value={categoryId}
							onValueChange={updateCategory}
						>
							<SelectTrigger>
								{selectedCategoryName}
							</SelectTrigger>
							<SelectContent>
								{#each data.categories as category (category.id)}
									<SelectItem value={category.id}>{category.name}</SelectItem>
								{/each}
							</SelectContent>
						</Select>
						{#each createItem.fields.category_id.issues() as issue, index (`${issue.message}-${index}`)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						<Field.Label>Container *</Field.Label>
						<Select
							type="single"
							name="container_id"
							value={containerId}
							onValueChange={updateContainer}
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
						{#each createItem.fields.container_id.issues() as issue, index (`${issue.message}-${index}`)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</div>

				<div class="grid gap-4 md:grid-cols-2">
					<Field.Field>
						<Field.Label>Quantity *</Field.Label>
						<Input
							type="number"
							min="1"
							name="quantity"
							value={quantity}
							oninput={(e) => {
								quantity = parseInt(e.currentTarget.value) || 1;
								createItem.fields.quantity.set(quantity);
							}}
						/>
						{#each createItem.fields.quantity.issues() as issue, index (`${issue.message}-${index}`)}
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
									createItem.fields.out_for_maintenance.set(outForMaintenance);
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
							createItem.fields.notes.set(notes);
						}}
						placeholder="Optional notes about this item"
						rows={3}
					/>
					{#each createItem.fields.notes.issues() as issue, index (`${issue.message}-${index}`)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
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
												class={attributeErrors[attr.name]
													? "text-destructive"
													: ""}
											>
												{attr.label}
												{#if attr.required}
													<span class="text-destructive">*</span>
												{/if}
											</Label>
											{#if attr.type === "text"}
												<Input
													id={attr.name}
													value={attributeText(attr.name)}
													placeholder={attr.label}
													class={attributeErrors[attr.name]
														? "border-destructive focus-visible:ring-destructive"
														: ""}
													oninput={(e) =>
														updateAttribute(attr.name, e.currentTarget.value)}
													aria-invalid={attributeErrors[attr.name]
														? "true"
														: undefined}
												/>
											{:else if attr.type === "number"}
												<Input
													id={attr.name}
													type="number"
													value={attributeNumber(attr.name)}
													placeholder={attr.label}
													class={attributeErrors[attr.name]
														? "border-destructive"
														: ""}
													oninput={(e) =>
														updateAttribute(
															attr.name,
															parseFloat(e.currentTarget.value),
														)}
												/>
											{:else if attr.type === "select" && attr.options}
												<Select
													type="single"
													value={attributeText(attr.name) || undefined}
													name="attributes.{attr.name}"
													onValueChange={(value) =>
														updateAttribute(attr.name, value)}
												>
													<SelectTrigger
														class={attributeErrors[attr.name]
															? "border-destructive"
															: ""}
													>
														{attributes[attr.name] ||
															`Select ${attr.label.toLowerCase()}`}
													</SelectTrigger>
													<SelectContent>
														{#each attr.options as option (option)}
															<SelectItem value={option}>{option}</SelectItem>
														{/each}
													</SelectContent>
												</Select>
											{:else if attr.type === "boolean"}
												<div class="flex items-center space-x-2">
													<Checkbox
														id={attr.name}
														name="attributes.{attr.name}"
														checked={!!attributes[attr.name]}
														onCheckedChange={(checked) =>
															updateAttribute(attr.name, !!checked)}
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

		<!-- Hidden field for attributes JSON -->
		<input type="hidden" name="attributes" value={JSON.stringify(attributes)} />

		<!-- Actions -->
		<div class="flex gap-3">
			<Button type="submit" disabled={!!createItem.pending}>
				{createItem.pending ? "Creating..." : "Create Item"}
			</Button>
			<Button href="/dashboard/inventory/items" variant="outline">Cancel</Button
			>
		</div>
	</form>
</div>
