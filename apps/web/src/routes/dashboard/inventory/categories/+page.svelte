<script lang="ts">
import { tick } from "svelte";
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
import * as AlertDialog from "$lib/components/ui/alert-dialog";
import { Badge } from "$lib/components/ui/badge";
import { Button, buttonVariants } from "$lib/components/ui/button";
import { Checkbox } from "$lib/components/ui/checkbox";
import * as DropdownMenu from "$lib/components/ui/dropdown-menu";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as Select from "$lib/components/ui/select";
import * as Sheet from "$lib/components/ui/sheet";
import InventoryPageHeader from "$lib/components/inventory/InventoryPageHeader.svelte";
import { apiErrorMessage } from "$lib/api-error";
import {
	Braces,
	ChevronRight,
	CircleDot,
	Ellipsis,
	Hash,
	Pencil,
	Plus,
	RefreshCw,
	Save,
	Search,
	Tags,
	Trash2,
} from "@lucide/svelte";
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
let categorySearch = $state("");
let categoryPendingDelete = $state<InventoryCategory | undefined>();
let categoryNameInput = $state<HTMLInputElement | null>(null);
let categoryEditorOpen = $state(false);
let categoryEditorTrigger = $state<HTMLElement | null>(null);
let propertyEditorOpen = $state(false);
let editingOptionId = $state<string | undefined>();
let optionDrafts = $state<Record<string, { label: string; position: number }>>(
	{},
);

const valueTypeOptions: { value: ValueType; label: string }[] = [
	{ value: "text", label: "Text" },
	{ value: "decimal", label: "Decimal number" },
	{ value: "boolean", label: "Yes / no" },
	{ value: "single_select", label: "Single select" },
];

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
const filteredCategories = $derived.by(() => {
	const query = categorySearch.trim().toLocaleLowerCase();
	if (!query) return categoriesQuery.data ?? [];
	return (categoriesQuery.data ?? []).filter(
		(category) =>
			category.name.toLocaleLowerCase().includes(query) ||
			category.description?.toLocaleLowerCase().includes(query),
	);
});
const totalItemCount = $derived(
	(categoriesQuery.data ?? []).reduce(
		(total, category) => total + category.itemCount,
		0,
	),
);
const activeDefinitions = $derived(
	(definitionsQuery.data ?? []).filter((definition) => !definition.retiredAt),
);

function refreshAll() {
	void categoriesQuery.refetch();
	void definitionsQuery.refetch();
}
const categoryCreate = createMutation(() => ({
	...inventoryCategoriesCreateMutation(),
	onSuccess: () => {
		toast.success("Category created");
		cancelCategoryEdit();
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Could not create category")),
}));
const categoryUpdate = createMutation(() => ({
	...inventoryCategoriesUpdateMutation(),
	onSuccess: () => {
		toast.success("Category updated");
		cancelCategoryEdit();
		refreshAll();
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Could not update category")),
}));
const categoryDelete = createMutation(() => ({
	...inventoryCategoriesDeleteMutation(),
	onSuccess: () => {
		toast.success("Category deleted");
		categoryPendingDelete = undefined;
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
		editingOptionId = undefined;
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
	propertyEditorOpen = false;
}
function editDefinition(definition: InventoryPropertyDefinition) {
	editingDefinition = definition;
	definitionLabel = definition.label;
	definitionType = definition.valueType;
	definitionRequired = definition.required;
	identifyingPosition = definition.identifyingPosition?.toString() ?? "";
	propertyEditorOpen = true;
}
function addDefinition() {
	resetDefinition();
	propertyEditorOpen = true;
}
async function editCategory(
	category: InventoryCategory,
	trigger?: HTMLElement,
) {
	categoryEditorTrigger = trigger ?? null;
	selectedCategoryId = category.id;
	editingCategory = category;
	categoryName = category.name;
	categoryDescription = category.description ?? "";
	categoryEditorOpen = true;
	await tick();
	categoryNameInput?.focus();
}
async function addCategory(trigger: HTMLElement) {
	categoryEditorTrigger = trigger;
	editingCategory = undefined;
	categoryName = "";
	categoryDescription = "";
	categoryEditorOpen = true;
	await tick();
	categoryNameInput?.focus();
}
function cancelCategoryEdit() {
	editingCategory = undefined;
	categoryName = "";
	categoryDescription = "";
	categoryEditorOpen = false;
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
function editOption(option: { id: string; label: string; position: number }) {
	optionDrafts[option.id] = { label: option.label, position: option.position };
	editingOptionId = option.id;
}
function cancelOptionEdit(optionId: string) {
	delete optionDrafts[optionId];
	editingOptionId = undefined;
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

{#snippet categoryAction()}
	<Button onclick={(event) => addCategory(event.currentTarget)}>
		<Plus aria-hidden="true" />New category
	</Button>
{/snippet}

<svelte:head><title>Inventory categories | Dublin HEMA Club</title></svelte:head
>
<div
	class="inventory-page inventory-categories-page xl:flex xl:h-[calc(100svh-2.8125rem)] xl:flex-col xl:overflow-hidden"
>
	<InventoryPageHeader
		eyebrow="Operator inventory"
		title="Categories and properties"
		icon={Tags}
		actions={categoryAction}
		class="xl:items-center xl:pb-3"
	/>
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
	<div
		class="flex flex-wrap items-center gap-x-5 gap-y-2 border-y border-border/60 px-1 py-3 text-sm text-muted-foreground"
	>
		<span
			><strong class="font-semibold text-foreground"
				>{categoriesQuery.data?.length ?? 0}</strong
			> categories</span
		>
		<span
			class="hidden size-1 rounded-full bg-border sm:block"
			aria-hidden="true"
		></span>
		<span
			><strong class="font-semibold text-foreground">{totalItemCount}</strong> physical
			items</span
		>
		{#if selectedCategory}
			<span
				class="hidden size-1 rounded-full bg-border sm:block"
				aria-hidden="true"
			></span>
			<span
				><strong class="font-semibold text-foreground"
					>{activeDefinitions.length}</strong
				>
				active properties in {selectedCategory.name}</span
			>
		{/if}
	</div>

	<div
		class="inventory-categories-workspace grid min-h-0 items-start gap-6 lg:grid-cols-[22rem_minmax(0,1fr)] xl:flex-1 xl:items-stretch"
	>
		<section
			class="inventory-categories-rail inventory-panel overflow-hidden lg:sticky lg:top-6 xl:static xl:flex xl:h-full xl:min-h-0 xl:flex-col"
		>
			<div class="border-b bg-muted/25 p-5">
				<div class="flex items-center justify-between gap-3">
					<div>
						<p
							class="text-xs font-semibold uppercase tracking-[0.16em] text-primary"
						>
							Taxonomy
						</p>
						<h2 class="mt-1 font-heading text-xl font-bold">Categories</h2>
					</div>
					<Badge variant="secondary">{categoriesQuery.data?.length ?? 0}</Badge>
				</div>
				<div class="relative mt-4">
					<Search
						class="pointer-events-none absolute left-3 top-3 size-4 text-muted-foreground"
						aria-hidden="true"
					/>
					<Label for="category-search" class="sr-only">Search categories</Label>
					<Input
						id="category-search"
						class="h-10 pl-9"
						placeholder="Search categories"
						bind:value={categorySearch}
					/>
				</div>
			</div>

			<div
				class="inventory-categories-list max-h-[38rem] space-y-2 overflow-y-auto p-3 lg:min-h-64 xl:min-h-0 xl:max-h-none xl:flex-1 xl:overscroll-contain xl:[scrollbar-gutter:stable]"
			>
				{#each filteredCategories as category (category.id)}
					<article
						class="group flex items-center rounded-xl border p-1.5 transition-colors {selectedCategoryId ===
						category.id
							? 'border-primary/55 bg-primary/7 shadow-sm'
							: 'bg-card hover:border-primary/30 hover:bg-muted/25'}"
					>
						<button
							type="button"
							class="flex min-w-0 flex-1 cursor-pointer items-center gap-3 rounded-lg p-2 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
							onclick={() => {
								selectedCategoryId = category.id;
								resetDefinition();
							}}
						>
							<span
								class="grid size-10 shrink-0 place-items-center rounded-lg {selectedCategoryId ===
								category.id
									? 'bg-primary text-primary-foreground'
									: 'bg-muted text-muted-foreground'}"
							>
								<Tags class="size-4" aria-hidden="true" />
							</span>
							<span class="min-w-0 flex-1">
								<span class="block truncate font-semibold">{category.name}</span
								>
								<span class="block text-xs text-muted-foreground"
									>{category.itemCount} items</span
								>
							</span>
						</button>
						<ChevronRight
							class="size-4 shrink-0 text-muted-foreground transition-transform group-hover:translate-x-0.5"
							aria-hidden="true"
						/>
						<DropdownMenu.Root>
							<DropdownMenu.Trigger
								class={buttonVariants({ variant: "ghost", size: "icon-sm" })}
								aria-label="Actions for {category.name}"
							>
								<Ellipsis aria-hidden="true" />
							</DropdownMenu.Trigger>
							<DropdownMenu.Content align="end" class="w-40">
								<DropdownMenu.Item onSelect={() => editCategory(category)}>
									<Pencil />Edit
								</DropdownMenu.Item>
								<DropdownMenu.Separator />
								<DropdownMenu.Item
									class="text-destructive focus:text-destructive"
									onSelect={() => (categoryPendingDelete = category)}
								>
									<Trash2 />Delete
								</DropdownMenu.Item>
							</DropdownMenu.Content>
						</DropdownMenu.Root>
					</article>
				{:else}
					<div class="grid min-h-32 place-items-center px-4 text-center">
						<p class="text-sm text-muted-foreground">
							No categories match “{categorySearch}”.
						</p>
					</div>
				{/each}
			</div>
		</section>

		<section
			class="inventory-categories-detail min-w-0 space-y-5 xl:h-full xl:min-h-0 xl:overflow-y-auto xl:overscroll-contain xl:pr-1 xl:[scrollbar-gutter:stable]"
		>
			{#if selectedCategory}
				<div class="inventory-panel overflow-hidden">
					<div class="relative border-b bg-primary/7 p-5 sm:p-6">
						<div
							class="absolute right-0 top-0 size-36 translate-x-1/3 -translate-y-1/3 rounded-full bg-secondary/20 blur-2xl"
							aria-hidden="true"
						></div>
						<div
							class="relative flex flex-wrap items-start justify-between gap-4"
						>
							<div class="flex min-w-0 items-start gap-4">
								<div
									class="grid size-12 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm"
								>
									<Tags class="size-5" aria-hidden="true" />
								</div>
								<div class="min-w-0">
									<p
										class="text-xs font-semibold uppercase tracking-[0.16em] text-primary"
									>
										Selected category
									</p>
									<h2 class="mt-1 font-heading text-2xl font-bold">
										{selectedCategory.name} properties
									</h2>
									<p class="mt-1 max-w-2xl text-sm text-muted-foreground">
										{selectedCategory.description ||
											"No category description yet."}
									</p>
								</div>
							</div>
							<div class="flex flex-wrap gap-2">
								<Button
									variant="outline"
									size="sm"
									onclick={(event) =>
										editCategory(selectedCategory, event.currentTarget)}
								>
									<Pencil />Edit category
								</Button>
								<Button size="sm" onclick={addDefinition}
									><Plus />Add property</Button
								>
							</div>
						</div>
						<div class="relative mt-5 flex flex-wrap gap-2">
							<Badge variant="secondary"
								>{selectedCategory.itemCount} items</Badge
							>
							<Badge variant="outline"
								>{activeDefinitions.length} active properties</Badge
							>
							{#if (definitionsQuery.data?.length ?? 0) > activeDefinitions.length}<Badge
									variant="outline"
									>{(definitionsQuery.data?.length ?? 0) -
										activeDefinitions.length} retired</Badge
								>{/if}
						</div>
					</div>

					{#if propertyEditorOpen}<form
							class="grid gap-4 p-5 sm:grid-cols-2 sm:p-6 xl:grid-cols-12"
							onsubmit={(event) => {
								event.preventDefault();
								submitDefinition();
							}}
						>
							<div class="sm:col-span-2 xl:col-span-12">
								<h3 class="font-heading text-lg font-bold">
									{editingDefinition ? "Edit property" : "Add a property"}
								</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Properties become the structured facts operators record for
									every item in this category.
								</p>
							</div>
							<div class="xl:col-span-4">
								<Label for="definition-label" class="mb-2">Label</Label>
								<Input
									id="definition-label"
									class="h-11"
									maxlength={100}
									placeholder="e.g. Jacket size"
									required
									bind:value={definitionLabel}
								/>
							</div>
							<div class="xl:col-span-4">
								<Label for="definition-type" class="mb-2">Value type</Label>
								<Select.Root
									type="single"
									items={valueTypeOptions}
									bind:value={definitionType}
									required
								>
									<Select.Trigger
										id="definition-type"
										class="w-full data-[size=default]:h-11"
									>
										{valueTypeOptions.find(
											(option) => option.value === definitionType,
										)?.label}
									</Select.Trigger>
									<Select.Content>
										{#each valueTypeOptions as option (option.value)}
											<Select.Item value={option.value} label={option.label}
												>{option.label}</Select.Item
											>
										{/each}
									</Select.Content>
								</Select.Root>
							</div>
							<div class="xl:col-span-4">
								<Label for="identifying-position" class="mb-2"
									>Label position</Label
								>
								<Input
									id="identifying-position"
									class="h-11"
									type="number"
									min="0"
									placeholder="Not in item label"
									bind:value={identifyingPosition}
								/>
							</div>
							<div
								class="flex items-center justify-between gap-4 rounded-xl border bg-muted/25 px-4 py-3 sm:col-span-2 xl:col-span-8"
							>
								<div>
									<Label for="definition-required" class="cursor-pointer"
										>Required</Label
									>
									<p class="text-xs text-muted-foreground">
										Every active item must carry this value.
									</p>
								</div>
								<Checkbox
									id="definition-required"
									class="size-5"
									bind:checked={definitionRequired}
								/>
							</div>
							<div
								class="flex items-center justify-end gap-2 sm:col-span-2 xl:col-span-4"
							>
								{#if editingDefinition}<Button
										type="button"
										variant="outline"
										onclick={resetDefinition}>Cancel</Button
									>{/if}
								<Button type="submit" class="min-w-36"
									><Save />{editingDefinition
										? "Save property"
										: "Add property"}</Button
								>
							</div>
						</form>{/if}
				</div>

				<div class="flex flex-wrap items-end justify-between gap-3 px-1">
					<div>
						<p
							class="text-xs font-semibold uppercase tracking-[0.16em] text-primary"
						>
							Item schema
						</p>
						<h2 class="mt-1 font-heading text-xl font-bold">
							Defined properties
						</h2>
					</div>
					<p class="text-sm text-muted-foreground">
						Required and type changes are checked against every active item.
					</p>
				</div>

				<div class="space-y-3">
					{#each definitionsQuery.data ?? [] as definition, index (definition.id)}
						<article
							class="inventory-panel overflow-hidden {definition.retiredAt
								? 'opacity-70'
								: ''}"
						>
							<div class="flex flex-wrap items-start gap-4 p-5">
								<div
									class="grid size-11 shrink-0 place-items-center rounded-xl bg-muted text-muted-foreground"
								>
									{#if definition.identifyingPosition !== null}<span
											class="font-mono text-sm font-bold"
											>{definition.identifyingPosition}</span
										>{:else}<Braces class="size-5" aria-hidden="true" />{/if}
								</div>
								<div class="min-w-0 flex-1">
									<div class="flex flex-wrap items-center gap-2">
										<h3 class="font-heading text-lg font-bold">
											{definition.label}
										</h3>
										<Badge variant="outline"
											>{valueTypeOptions.find(
												(option) => option.value === definition.valueType,
											)?.label}</Badge
										>
										{#if definition.required}<Badge>Required</Badge>{/if}
										{#if definition.identifyingPosition !== null}<Badge
												variant="secondary"
												>Item label #{definition.identifyingPosition}</Badge
											>{/if}
										{#if definition.retiredAt}<Badge variant="destructive"
												>Retired</Badge
											>{/if}
									</div>
									<p
										class="mt-2 flex items-center gap-1.5 text-xs text-muted-foreground"
									>
										<CircleDot class="size-3.5" aria-hidden="true" />Property {index +
											1} · <span class="font-mono">{definition.id}</span>
									</p>
								</div>
								{#if !definition.retiredAt}
									<div class="ml-auto flex gap-2">
										<Button
											size="sm"
											variant="outline"
											onclick={() => editDefinition(definition)}
											><Pencil />Edit</Button
										>
										<Button
											size="sm"
											variant="ghost"
											class="text-destructive hover:bg-destructive/10 hover:text-destructive"
											onclick={() =>
												definitionRetire.mutate({
													path: { id: definition.id },
												})}>Retire</Button
										>
									</div>
								{/if}
							</div>

							{#if definition.valueType === "single_select"}
								<div class="border-t bg-muted/20 p-5">
									<div class="mb-3 flex items-center justify-between gap-3">
										<div>
											<h4 class="font-semibold">Allowed options</h4>
											<p class="text-xs text-muted-foreground">
												Order controls how choices appear in item forms.
											</p>
										</div>
										<Badge variant="outline"
											>{definition.options.filter((option) => !option.retiredAt)
												.length} active</Badge
										>
									</div>
									<div class="space-y-2">
										{#each definition.options as option (option.id)}
											{@const draft = optionDraft(option)}
											{#if editingOptionId === option.id}
												<div
													class="grid gap-2 rounded-xl border border-primary/35 bg-background p-3 sm:grid-cols-[minmax(0,1fr)_6rem_auto] sm:items-center"
												>
													<Input
														value={draft.label}
														aria-label="{option.label} label"
														oninput={(event) =>
															setOptionDraft(
																option,
																"label",
																event.currentTarget.value,
															)}
													/>
													<div class="relative">
														<Hash
															class="pointer-events-none absolute left-2.5 top-2.5 size-4 text-muted-foreground"
															aria-hidden="true"
														/>
														<Input
															class="pl-8"
															type="number"
															min="0"
															value={draft.position}
															aria-label="{option.label} position"
															oninput={(event) =>
																setOptionDraft(
																	option,
																	"position",
																	event.currentTarget.value,
																)}
														/>
													</div>
													<div class="flex gap-1 sm:justify-end">
														<Button size="sm" onclick={() => saveOption(option)}
															>Save</Button
														>
														<Button
															size="sm"
															variant="ghost"
															onclick={() => cancelOptionEdit(option.id)}
															>Cancel</Button
														>
													</div>
												</div>
											{:else}
												<div
													class="flex min-h-12 items-center gap-3 rounded-xl border bg-background px-3 py-2.5"
												>
													<span
														class="grid size-8 shrink-0 place-items-center rounded-lg bg-muted font-mono text-xs font-bold text-muted-foreground"
														>{option.position}</span
													>
													<span class="min-w-0 flex-1 truncate font-medium"
														>{option.label}</span
													>
													{#if option.retiredAt}
														<Badge variant="outline">Retired</Badge>
													{:else}
														<div class="flex gap-1">
															<Button
																size="sm"
																variant="ghost"
																aria-label="Edit {option.label}"
																onclick={() => editOption(option)}
																><Pencil />Edit</Button
															>
															<Button
																size="sm"
																variant="ghost"
																class="text-destructive hover:bg-destructive/10 hover:text-destructive"
																onclick={() =>
																	optionRetire.mutate({
																		path: { id: option.id },
																	})}>Retire</Button
															>
														</div>
													{/if}
												</div>
											{/if}
										{/each}
									</div>
									{#if !definition.retiredAt}
										<form
											class="mt-3 flex gap-2 rounded-xl border border-dashed bg-background/70 p-2.5"
											onsubmit={(event) => {
												event.preventDefault();
												addOption(event.currentTarget, definition.id);
											}}
										>
											<Input
												name="label"
												maxlength={100}
												aria-label="New option label"
												placeholder="Add another option"
												required
											/>
											<Button type="submit" size="sm"><Plus />Add</Button>
										</form>
									{/if}
								</div>
							{/if}
						</article>
					{:else}
						<div
							class="inventory-panel grid min-h-48 place-items-center border-dashed p-8 text-center"
						>
							<div class="max-w-sm">
								<div
									class="mx-auto grid size-11 place-items-center rounded-xl bg-muted text-muted-foreground"
								>
									<Braces class="size-5" aria-hidden="true" />
								</div>
								<h3 class="mt-3 font-semibold">No properties yet</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Add the first structured fact for {selectedCategory.name} above.
								</p>
							</div>
						</div>
					{/each}
				</div>
			{:else}
				<div
					class="inventory-panel grid min-h-[32rem] place-items-center border-dashed p-8 text-center"
				>
					<div class="max-w-md">
						<div
							class="mx-auto grid size-14 place-items-center rounded-2xl bg-primary/10 text-primary"
						>
							<Tags class="size-6" aria-hidden="true" />
						</div>
						<h2 class="mt-4 font-heading text-2xl font-bold">
							Choose a category
						</h2>
						<p class="mt-2 text-sm leading-relaxed text-muted-foreground">
							Select a category from the library to shape its item labels,
							required facts, and allowed options.
						</p>
					</div>
				</div>
			{/if}
		</section>
	</div>
</div>

<Sheet.Root
	bind:open={categoryEditorOpen}
	onOpenChange={(open) => {
		if (!open) cancelCategoryEdit();
	}}
	onOpenChangeComplete={(open) => {
		if (!open) categoryEditorTrigger?.focus();
	}}
>
	<Sheet.Content
		side="right"
		class="w-full max-w-none gap-0 overflow-hidden p-0 sm:w-[30rem] sm:max-w-[calc(100vw-2rem)]"
	>
		<Sheet.Header
			class="shrink-0 border-b bg-primary/7 px-5 pt-[max(1.25rem,env(safe-area-inset-top))] pr-16 pb-5 text-left sm:px-6 sm:pt-6"
		>
			<div class="flex items-start gap-3">
				<div
					class="grid size-11 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm"
				>
					{#if editingCategory}<Pencil
							class="size-5"
							aria-hidden="true"
						/>{:else}<Plus class="size-5" aria-hidden="true" />{/if}
				</div>
				<div>
					<Sheet.Title class="font-heading text-2xl font-bold"
						>{editingCategory ? "Edit category" : "New category"}</Sheet.Title
					>
					<Sheet.Description class="mt-1"
						>Define the broad family an inventory item belongs to.</Sheet.Description
					>
				</div>
			</div>
		</Sheet.Header>
		<form
			class="flex min-h-0 flex-1 flex-col"
			onsubmit={(event) => {
				event.preventDefault();
				submitCategory();
			}}
		>
			<div
				class="min-h-0 flex-1 space-y-5 overflow-y-auto bg-muted/20 p-5 sm:p-6"
			>
				<div class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm">
					<div>
						<Label for="category-name" class="mb-2.5">Name</Label>
						<Input
							bind:ref={categoryNameInput}
							id="category-name"
							class="h-11"
							maxlength={50}
							placeholder="e.g. Training swords"
							required
							bind:value={categoryName}
						/>
					</div>
					<div>
						<Label for="category-description" class="mb-2.5">Description</Label>
						<Input
							id="category-description"
							class="h-11"
							maxlength={500}
							placeholder="What belongs in this category?"
							bind:value={categoryDescription}
						/>
						<p class="mt-2 text-xs leading-relaxed text-muted-foreground">
							Use a stable description that helps future operators classify
							equipment consistently.
						</p>
					</div>
				</div>
			</div>
			<Sheet.Footer
				class="shrink-0 flex-row border-t bg-background p-4 sm:px-6"
			>
				<Button
					type="button"
					variant="outline"
					class="flex-1"
					onclick={cancelCategoryEdit}>Cancel</Button
				>
				<Button
					type="submit"
					class="flex-1"
					disabled={categoryCreate.isPending || categoryUpdate.isPending}
				>
					{editingCategory ? "Save" : "Add category"}
				</Button>
			</Sheet.Footer>
		</form>
	</Sheet.Content>
</Sheet.Root>

<AlertDialog.Root
	open={Boolean(categoryPendingDelete)}
	onOpenChange={(open) => {
		if (!open) categoryPendingDelete = undefined;
	}}
>
	<AlertDialog.Content>
		<AlertDialog.Header>
			<AlertDialog.Title
				>Delete {categoryPendingDelete?.name}?</AlertDialog.Title
			>
			<AlertDialog.Description
				>This category can only be deleted when no items refer to it. This
				action cannot be undone.</AlertDialog.Description
			>
		</AlertDialog.Header>
		<AlertDialog.Footer>
			<AlertDialog.Cancel>Cancel</AlertDialog.Cancel>
			<AlertDialog.Action
				class={buttonVariants({ variant: "destructive" })}
				disabled={categoryDelete.isPending}
				onclick={() => {
					if (categoryPendingDelete)
						categoryDelete.mutate({ path: { id: categoryPendingDelete.id } });
				}}
			>
				Delete category
			</AlertDialog.Action>
		</AlertDialog.Footer>
	</AlertDialog.Content>
</AlertDialog.Root>
