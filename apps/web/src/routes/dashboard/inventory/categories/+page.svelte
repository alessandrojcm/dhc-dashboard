<script lang="ts">
import { createMutation, createQuery } from "@tanstack/svelte-query";
import {
	type InventoryCategory,
	type InventoryPropertyDefinition,
	inventoryCategoriesCreateMutation,
	inventoryCategoriesDeleteMutation,
	inventoryCategoriesIndexOptions,
	inventoryCategoriesUpdateMutation,
	inventoryStructureCreateDefinitionMutation,
	inventoryStructureCreateOptionMutation,
	inventoryStructureListDefinitionsOptions,
	inventoryStructureRetireDefinitionMutation,
	inventoryStructureRetireOptionMutation,
	inventoryStructureUpdateDefinitionMutation,
	inventoryStructureUpdateOptionMutation,
} from "@dhc/api-client";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import { apiErrorMessage } from "$lib/api-error";
import { Plus, RefreshCw, Save, Trash2 } from "@lucide/svelte";
import { toast } from "svelte-sonner";

type ValueType = "text" | "decimal" | "boolean" | "single_select";
let selectedCategoryId = $state<string | undefined>();
let editingCategory = $state<InventoryCategory | undefined>();
let categoryName = $state("");
let categoryDescription = $state("");
let editingDefinition = $state<InventoryPropertyDefinition | undefined>();
let definitionLabel = $state("");
let definitionType = $state<ValueType>("text");
let definitionRequired = $state(false);
let identifyingPosition = $state("");
let optionDrafts = $state<Record<string, { label: string; position: number }>>(
	{},
);

const categoriesQuery = createQuery(() => ({
	...inventoryCategoriesIndexOptions(),
	select: (response) => response.data.categories,
}));
const definitionsQuery = createQuery(() => ({
	...inventoryStructureListDefinitionsOptions({
		path: { categoryId: selectedCategoryId! },
	}),
	enabled: Boolean(selectedCategoryId),
	select: (response) => response.data.definitions,
}));
const selectedCategory = $derived(
	categoriesQuery.data?.find((category) => category.id === selectedCategoryId),
);

function refreshAll() {
	void categoriesQuery.refetch();
	void definitionsQuery.refetch();
}
const categoryCreate = createMutation(() => ({
	...inventoryCategoriesCreateMutation(),
	onSuccess: () => {
		toast.success("Category created");
		categoryName = "";
		categoryDescription = "";
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Could not create category")),
}));
const categoryUpdate = createMutation(() => ({
	...inventoryCategoriesUpdateMutation(),
	onSuccess: () => {
		toast.success("Category updated");
		editingCategory = undefined;
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Could not update category")),
}));
const categoryDelete = createMutation(() => ({
	...inventoryCategoriesDeleteMutation(),
	onSuccess: () => {
		toast.success("Category deleted");
		selectedCategoryId = undefined;
		refreshAll();
	},
	onError: (error) =>
		toast.error(
			apiErrorMessage(error, "Move its items before deleting this category"),
		),
}));
const definitionCreate = createMutation(() => ({
	...inventoryStructureCreateDefinitionMutation(),
	onSuccess: () => {
		toast.success("Property created");
		resetDefinition();
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Could not create property")),
}));
const definitionUpdate = createMutation(() => ({
	...inventoryStructureUpdateDefinitionMutation(),
	onSuccess: () => {
		toast.success("Property updated");
		resetDefinition();
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Could not update property")),
}));
const definitionRetire = createMutation(() => ({
	...inventoryStructureRetireDefinitionMutation(),
	onSuccess: () => {
		toast.success("Property retired");
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Clear or migrate active values first")),
}));
const optionCreate = createMutation(() => ({
	...inventoryStructureCreateOptionMutation(),
	onSuccess: () => {
		toast.success("Option created");
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Could not create option")),
}));
const optionUpdate = createMutation(() => ({
	...inventoryStructureUpdateOptionMutation(),
	onSuccess: () => {
		toast.success("Option updated");
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Could not update option")),
}));
const optionRetire = createMutation(() => ({
	...inventoryStructureRetireOptionMutation(),
	onSuccess: () => {
		toast.success("Option retired");
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Clear or migrate active values first")),
}));

function resetDefinition() {
	editingDefinition = undefined;
	definitionLabel = "";
	definitionType = "text";
	definitionRequired = false;
	identifyingPosition = "";
}
function editDefinition(definition: InventoryPropertyDefinition) {
	editingDefinition = definition;
	definitionLabel = definition.label;
	definitionType = definition.valueType;
	definitionRequired = definition.required;
	identifyingPosition = definition.identifyingPosition?.toString() ?? "";
}
function optionDraft(option: { id: string; label: string; position: number }) {
	return (
		optionDrafts[option.id] ?? {
			label: option.label,
			position: option.position,
		}
	);
}
function setOptionDraft(
	option: { id: string; label: string; position: number },
	field: "label" | "position",
	value: string,
) {
	const current = optionDraft(option);
	optionDrafts[option.id] = {
		...current,
		[field]: field === "position" ? Number(value) : value,
	};
}
function saveOption(option: { id: string; label: string; position: number }) {
	const draft = optionDraft(option);
	optionUpdate.mutate({ path: { id: option.id }, body: draft });
}
function submitCategory() {
	const body = {
		name: categoryName.trim(),
		description: categoryDescription.trim() || null,
	};
	if (!body.name) return;
	if (editingCategory)
		categoryUpdate.mutate({ path: { id: editingCategory.id }, body });
	else categoryCreate.mutate({ body });
}
function submitDefinition() {
	if (!selectedCategoryId || !definitionLabel.trim()) return;
	const body = {
		label: definitionLabel.trim(),
		valueType: definitionType,
		required: definitionRequired,
		identifyingPosition:
			identifyingPosition === "" ? null : Number(identifyingPosition),
	};
	if (editingDefinition)
		definitionUpdate.mutate({ path: { id: editingDefinition.id }, body });
	else
		definitionCreate.mutate({ path: { categoryId: selectedCategoryId }, body });
}
function addOption(form: HTMLFormElement, definitionId: string) {
	const input = form.elements.namedItem("label");
	if (!(input instanceof HTMLInputElement)) return;
	if (!input.value.trim()) return;
	optionCreate.mutate({
		path: { definitionId },
		body: { label: input.value.trim() },
	});
	form.reset();
}
</script>

<svelte:head><title>Inventory categories | Dublin HEMA Club</title></svelte:head
>
<div class="mx-auto max-w-6xl space-y-6 px-4 py-8 sm:px-6">
	<header>
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Operator inventory
		</p>
		<h1 class="font-heading text-3xl font-bold">Categories and properties</h1>
		<p class="mt-2 text-sm text-muted-foreground">
			Property identities remain stable when labels change. Retired values stay
			visible in history.
		</p>
	</header>
	{#if categoriesQuery.isError}<Alert variant="destructive"
			><AlertDescription class="flex items-center justify-between"
				><span
					>{apiErrorMessage(
						categoriesQuery.error,
						"Could not load categories",
					)}</span
				><Button
					variant="outline"
					size="sm"
					onclick={() => categoriesQuery.refetch()}
					><RefreshCw />Try again</Button
				></AlertDescription
			></Alert
		>{/if}
	<div class="grid gap-6 lg:grid-cols-[20rem_1fr]">
		<section class="space-y-4 rounded-2xl border bg-card p-5">
			<h2 class="text-lg font-semibold">Categories</h2>
			<form
				class="space-y-3"
				onsubmit={(event) => {
					event.preventDefault();
					submitCategory();
				}}
			>
				<div>
					<Label for="category-name">Name</Label><Input
						id="category-name"
						maxlength={50}
						required
						bind:value={categoryName}
					/>
				</div>
				<div>
					<Label for="category-description">Description</Label><Input
						id="category-description"
						maxlength={500}
						bind:value={categoryDescription}
					/>
				</div>
				<div class="flex gap-2">
					<Button
						type="submit"
						disabled={categoryCreate.isPending || categoryUpdate.isPending}
						>{editingCategory ? "Save" : "Add category"}</Button
					>{#if editingCategory}<Button
							type="button"
							variant="outline"
							onclick={() => {
								editingCategory = undefined;
								categoryName = "";
								categoryDescription = "";
							}}>Cancel</Button
						>{/if}
				</div>
			</form>
			<div class="space-y-2">
				{#each categoriesQuery.data ?? [] as category (category.id)}
					<div
						class="rounded-xl border p-3 {selectedCategoryId === category.id
							? 'border-primary bg-primary/5'
							: ''}"
					>
						<button
							type="button"
							class="w-full cursor-pointer text-left"
							onclick={() => {
								selectedCategoryId = category.id;
								resetDefinition();
							}}
							><span class="font-semibold">{category.name}</span><span
								class="block text-xs text-muted-foreground"
								>{category.itemCount} items</span
							></button
						>
						<div class="mt-2 flex gap-2">
							<Button
								size="sm"
								variant="outline"
								onclick={() => {
									selectedCategoryId = category.id;
									editingCategory = category;
									categoryName = category.name;
									categoryDescription = category.description ?? "";
								}}>Edit</Button
							><Button
								size="sm"
								variant="ghost"
								class="text-destructive"
								aria-label="Delete {category.name}"
								onclick={() =>
									categoryDelete.mutate({ path: { id: category.id } })}
								><Trash2 /></Button
							>
						</div>
					</div>
				{/each}
			</div>
		</section>
		<section class="space-y-5 rounded-2xl border bg-card p-5">
			{#if selectedCategory}<div>
					<h2 class="text-xl font-semibold">
						{selectedCategory.name} properties
					</h2>
					<p class="text-sm text-muted-foreground">
						Required and type changes are checked against every active item.
					</p>
				</div>
				<form
					class="grid gap-3 rounded-xl bg-muted/40 p-4 sm:grid-cols-2"
					onsubmit={(event) => {
						event.preventDefault();
						submitDefinition();
					}}
				>
					<div>
						<Label for="definition-label">Label</Label><Input
							id="definition-label"
							maxlength={100}
							required
							bind:value={definitionLabel}
						/>
					</div>
					<div>
						<Label for="definition-type">Value type</Label><select
							id="definition-type"
							class="h-10 w-full rounded-md border bg-background px-3"
							bind:value={definitionType}
							><option value="text">Text</option><option value="decimal"
								>Decimal</option
							><option value="boolean">Boolean</option><option
								value="single_select">Single select</option
							></select
						>
					</div>
					<div>
						<Label for="identifying-position">Identifying position</Label><Input
							id="identifying-position"
							type="number"
							min="0"
							placeholder="Not identifying"
							bind:value={identifyingPosition}
						/>
					</div>
					<label class="flex items-center gap-2 self-end pb-2"
						><input type="checkbox" bind:checked={definitionRequired} /> Required</label
					>
					<div class="flex gap-2 sm:col-span-2">
						<Button type="submit"
							><Save />{editingDefinition
								? "Save property"
								: "Add property"}</Button
						>{#if editingDefinition}<Button
								type="button"
								variant="outline"
								onclick={resetDefinition}>Cancel</Button
							>{/if}
					</div>
				</form>
				<div class="space-y-3">
					{#each definitionsQuery.data ?? [] as definition (definition.id)}<article
							class="rounded-xl border p-4"
						>
							<div class="flex flex-wrap items-start justify-between gap-3">
								<div>
									<div class="flex flex-wrap items-center gap-2">
										<h3 class="font-semibold">{definition.label}</h3>
										<Badge variant="outline"
											>{definition.valueType.replace("_", " ")}</Badge
										>{#if definition.required}<Badge>Required</Badge
											>{/if}{#if definition.identifyingPosition !== null}<Badge
												variant="secondary"
												>Label #{definition.identifyingPosition}</Badge
											>{/if}{#if definition.retiredAt}<Badge
												variant="destructive">Retired</Badge
											>{/if}
									</div>
									<p class="mt-1 font-mono text-xs text-muted-foreground">
										{definition.id}
									</p>
								</div>
								{#if !definition.retiredAt}<div class="flex gap-2">
										<Button
											size="sm"
											variant="outline"
											onclick={() => editDefinition(definition)}>Edit</Button
										><Button
											size="sm"
											variant="destructive"
											onclick={() =>
												definitionRetire.mutate({
													path: { id: definition.id },
												})}>Retire</Button
										>
									</div>{/if}
							</div>
							{#if definition.valueType === "single_select"}<div
									class="mt-4 border-t pt-4"
								>
									<p class="mb-2 text-sm font-medium">Options</p>
									<div class="space-y-2">
										{#each definition.options as option (option.id)}{@const draft =
												optionDraft(option)}
											<div class="flex items-center gap-2">
												<Input
													value={draft.label}
													aria-label="{option.label} label"
													disabled={Boolean(option.retiredAt)}
													oninput={(event) =>
														setOptionDraft(
															option,
															"label",
															event.currentTarget.value,
														)}
												/><Input
													class="w-20"
													type="number"
													min="0"
													value={draft.position}
													aria-label="{option.label} position"
													disabled={Boolean(option.retiredAt)}
													oninput={(event) =>
														setOptionDraft(
															option,
															"position",
															event.currentTarget.value,
														)}
												/>{#if option.retiredAt}<Badge variant="outline"
														>Retired</Badge
													>{:else}<Button
														size="sm"
														variant="outline"
														onclick={() => saveOption(option)}>Save</Button
													><Button
														size="sm"
														variant="outline"
														onclick={() =>
															optionRetire.mutate({ path: { id: option.id } })}
														>Retire</Button
													>{/if}
											</div>{/each}
									</div>
									{#if !definition.retiredAt}<form
											class="mt-3 flex gap-2"
											onsubmit={(event) => {
												event.preventDefault();
												addOption(event.currentTarget, definition.id);
											}}
										>
											<Input
												name="label"
												maxlength={100}
												aria-label="New option label"
												placeholder="New option"
												required
											/><Button type="submit" size="sm"><Plus />Add</Button>
										</form>{/if}
								</div>{/if}
						</article>{/each}
				</div>
			{:else}<div
					class="grid min-h-72 place-items-center text-center text-muted-foreground"
				>
					<div>
						<h2 class="font-semibold text-foreground">Choose a category</h2>
						<p class="text-sm">
							Select one to manage its property definitions.
						</p>
					</div>
				</div>{/if}
		</section>
	</div>
</div>
