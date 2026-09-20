<script lang="ts">
import { tick } from "svelte";
import { afterNavigate, goto } from "$app/navigation";
import { page } from "$app/state";
import { createMutation, createQuery } from "@tanstack/svelte-query";
import {
	type InventoryCategory,
	type InventoryPropertyDefinition,
	inventoryCategoriesDeleteMutation,
	inventoryCategoriesIndexOptions,
	inventoryStructureListDefinitionsOptions,
	inventoryStructureRetireDefinitionMutation,
	inventoryStructureRetireOptionMutation,
} from "@dhc/api-client";
import {
	createOption,
	saveCategory,
	saveDefinition,
	updateOption,
} from "./data.remote";
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
import SubmitButton from "$lib/components/ui/submit-button.svelte";
import { apiErrorMessage } from "$lib/api-error";
import {
	ArrowLeft,
	Braces,
	ChevronRight,
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
const LIST_PATH = "/dashboard/inventory/categories";
const selectedCategoryId = $derived(page.params.categoryId);
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
let categorySucceeded = $state(false);
let definitionSucceeded = $state(false);
let categoryTimer: ReturnType<typeof setTimeout> | undefined;
let definitionTimer: ReturnType<typeof setTimeout> | undefined;
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
const retiredDefinitionCount = $derived(
	(definitionsQuery.data?.length ?? 0) - activeDefinitions.length,
);

afterNavigate(({ from, to }) => {
	if (from?.url.pathname !== to?.url.pathname) {
		resetDefinition();
		editingOptionId = undefined;
	}
});

function refreshAll() {
	void categoriesQuery.refetch();
	void definitionsQuery.refetch();
}
function formatCount(count: number, singular: string, plural = `${singular}s`) {
	return `${count} ${count === 1 ? singular : plural}`;
}
const categoryDelete = createMutation(() => ({
	...inventoryCategoriesDeleteMutation(),
	onSuccess: (_response, variables) => {
		toast.success("Category deleted");
		categoryPendingDelete = undefined;
		refreshAll();
		if (variables.path.id === selectedCategoryId) void goto(LIST_PATH);
	},
	onError: (error) =>
		toast.error(
			apiErrorMessage(error, "Move its items before deleting this category"),
		),
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
	definitionSucceeded = false;
	clearTimeout(definitionTimer);
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
	categorySucceeded = false;
	clearTimeout(categoryTimer);
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
function editOption(option: { id: string; label: string; position: number }) {
	optionDrafts[option.id] = { label: option.label, position: option.position };
	editingOptionId = option.id;
}
function cancelOptionEdit(optionId: string) {
	delete optionDrafts[optionId];
	editingOptionId = undefined;
}
function handleCategorySave(result: typeof saveCategory.result) {
	if (!result) return;
	// Errors render inline in the sheet; success flashes the submit button
	// green and then closes — no toast to linger over the list.
	if (!result.ok) return;
	categorySucceeded = true;
	refreshAll();
	clearTimeout(categoryTimer);
	categoryTimer = setTimeout(() => cancelCategoryEdit(), 650);
}
function handleDefinitionSave(result: typeof saveDefinition.result) {
	if (!result) return;
	if (!result.ok) return;
	definitionSucceeded = true;
	refreshAll();
	clearTimeout(definitionTimer);
	definitionTimer = setTimeout(() => resetDefinition(), 650);
}
function handleOptionCreate(result: typeof createOption.result) {
	if (!result) return false;
	if (!result.ok) return false;
	refreshAll();
	return true;
}
function handleOptionUpdate(result: typeof updateOption.result) {
	if (!result) return;
	if (!result.ok) return;
	editingOptionId = undefined;
	refreshAll();
}
</script>

{#snippet categoryAction()}
	<Button
		class="max-lg:hidden"
		onclick={(event) => addCategory(event.currentTarget)}
	>
		<Plus aria-hidden="true" />New category
	</Button>
{/snippet}

<svelte:head>
	<title
		>{selectedCategory
			? `${selectedCategory.name} properties`
			: "Inventory categories"} | Dublin HEMA Club</title
	>
</svelte:head>
<div
	class="inventory-page inventory-categories-page xl:flex xl:h-[calc(100svh-2.8125rem)] xl:flex-col xl:overflow-hidden"
>
	<InventoryPageHeader
		eyebrow="Quartermaster"
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
		<span class="font-semibold text-foreground">
			{formatCount(categoriesQuery.data?.length ?? 0, "category", "categories")}
		</span>
		<span
			class="hidden size-1 rounded-full bg-border sm:block"
			aria-hidden="true"
		></span>
		<span class="font-semibold text-foreground">
			{formatCount(totalItemCount, "item")}
		</span>
		{#if selectedCategory}
			<span
				class="hidden size-1 rounded-full bg-border sm:block"
				aria-hidden="true"
			></span>
			<span>
				<strong class="font-semibold text-foreground">
					{formatCount(
						activeDefinitions.length,
						"active property",
						"active properties",
					)}
				</strong>
				in {selectedCategory.name}
			</span>
		{/if}
	</div>

	<div
		class="inventory-categories-workspace grid min-h-0 items-start gap-6 lg:grid-cols-[22rem_minmax(0,1fr)] xl:flex-1 xl:items-stretch"
	>
		<section
			class="inventory-categories-rail inventory-panel overflow-hidden lg:sticky lg:top-6 xl:static xl:flex xl:h-full xl:min-h-0 xl:flex-col {selectedCategoryId
				? 'max-lg:hidden'
				: 'max-lg:animate-in max-lg:fade-in-0 max-lg:slide-in-from-left-4 max-lg:duration-200 max-lg:motion-reduce:animate-none'}"
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
					<div class="flex shrink-0 items-center gap-2">
						<Badge variant="secondary"
							>{categoriesQuery.data?.length ?? 0}</Badge
						>
						<Button
							size="sm"
							class="min-h-11 lg:hidden"
							onclick={(event) => addCategory(event.currentTarget)}
						>
							<Plus aria-hidden="true" />New category
						</Button>
					</div>
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
						<a
							href="{LIST_PATH}/{category.id}"
							class="flex min-w-0 flex-1 cursor-pointer items-center gap-3 rounded-lg p-2 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
							aria-current={selectedCategoryId === category.id
								? "page"
								: undefined}
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
								<span class="block text-xs text-muted-foreground">
									{formatCount(category.itemCount, "item")}
								</span>
							</span>
						</a>
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
			class="inventory-categories-detail min-w-0 space-y-5 xl:h-full xl:min-h-0 xl:overflow-y-auto xl:overscroll-contain xl:pr-1 xl:[scrollbar-gutter:stable] {selectedCategoryId
				? 'max-lg:animate-in max-lg:fade-in-0 max-lg:slide-in-from-right-4 max-lg:duration-200 max-lg:motion-reduce:animate-none'
				: 'max-lg:hidden'}"
		>
			{#if selectedCategoryId}
				<Button
					href={LIST_PATH}
					variant="ghost"
					class="min-h-11 px-2 lg:hidden"
				>
					<ArrowLeft aria-hidden="true" />
					All categories
				</Button>
			{/if}
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
									class="min-h-11 sm:min-h-9"
									onclick={(event) =>
										editCategory(selectedCategory, event.currentTarget)}
								>
									<Pencil />Edit category
								</Button>
								<Button
									size="sm"
									class="min-h-11 sm:min-h-9"
									onclick={addDefinition}><Plus />Add property</Button
								>
							</div>
						</div>
						<div class="relative mt-5 flex flex-wrap gap-2">
							<Badge variant="secondary">
								{formatCount(selectedCategory.itemCount, "item")}
							</Badge>
							<Badge variant="outline">
								{formatCount(
									activeDefinitions.length,
									"active property",
									"active properties",
								)}
							</Badge>
							{#if retiredDefinitionCount > 0}<Badge variant="outline">
									{formatCount(
										retiredDefinitionCount,
										"retired property",
										"retired properties",
									)}
								</Badge>{/if}
						</div>
					</div>

					{#if propertyEditorOpen}<form
							{...saveDefinition.enhance(async (form) => {
								if (await form.submit()) handleDefinitionSave(form.result);
							})}
							class="grid gap-4 p-5 sm:grid-cols-2 sm:p-6 xl:grid-cols-12"
						>
							<input
								type="hidden"
								name={saveDefinition.fields.categoryId.as(
									"hidden",
									selectedCategoryId ?? "",
								).name}
								value={selectedCategoryId ?? ""}
							/>
							<input
								type="hidden"
								name={saveDefinition.fields.definitionId.as(
									"hidden",
									editingDefinition?.id ?? "",
								).name}
								value={editingDefinition?.id ?? ""}
							/>
							<input
								type="hidden"
								name={saveDefinition.fields.valueType.as(
									"hidden",
									definitionType,
								).name}
								value={definitionType}
							/>
							<input
								type="hidden"
								name={saveDefinition.fields.required.as(
									"hidden",
									String(definitionRequired),
								).name}
								value={String(definitionRequired)}
							/>
							<input
								type="hidden"
								name={saveDefinition.fields.identifyingPosition.as(
									"hidden",
									identifyingPosition,
								).name}
								value={identifyingPosition}
							/>
							{#each saveDefinition.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
									role="alert"
									class="text-sm text-destructive sm:col-span-2 xl:col-span-12"
								>
									{issue.message}
								</p>{/each}
							{#if saveDefinition.result && !saveDefinition.result.ok}<p
									role="alert"
									class="text-sm text-destructive sm:col-span-2 xl:col-span-12"
								>
									{saveDefinition.result.error}
								</p>{/if}
							<div class="sm:col-span-2 xl:col-span-12">
								<h3 class="font-heading text-lg font-bold">
									{editingDefinition ? "Edit property" : "Add a property"}
								</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Properties are the details quartermasters fill in for every
									item in this category.
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
									name={saveDefinition.fields.label.as("text").name}
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
									value={identifyingPosition}
									oninput={(event) =>
										(identifyingPosition = event.currentTarget.value)}
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
								<SubmitButton
									type="submit"
									class="min-w-36"
									disabled={saveDefinition.pending > 0}
									pending={saveDefinition.pending > 0}
									succeeded={definitionSucceeded}
									pendingLabel={editingDefinition ? "Saving…" : "Adding…"}
									successLabel={editingDefinition ? "Saved" : "Added"}
								>
									<Save />{editingDefinition ? "Save property" : "Add property"}
								</SubmitButton>
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
							<div
								class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-start gap-3 p-4 sm:gap-4 sm:p-5"
							>
								<div
									class="grid size-11 shrink-0 place-items-center rounded-xl bg-muted text-muted-foreground"
								>
									<Braces class="size-5" aria-hidden="true" />
								</div>
								<div class="min-w-0">
									<h3 class="font-heading text-lg font-bold leading-tight">
										{definition.label}
									</h3>
									<div class="mt-2 flex flex-wrap items-center gap-1.5">
										<Badge variant="outline"
											>{valueTypeOptions.find(
												(option) => option.value === definition.valueType,
											)?.label}</Badge
										>
										{#if definition.required}<Badge>Required</Badge>{/if}
										{#if definition.identifyingPosition !== null}<Badge
												variant="secondary"
												>Item label position {definition.identifyingPosition}</Badge
											>{/if}
										{#if definition.retiredAt}<Badge variant="destructive"
												>Retired</Badge
											>{/if}
									</div>
									<p class="mt-2 text-xs text-muted-foreground">
										Property {index + 1} of {definitionsQuery.data?.length ?? 0}
									</p>
								</div>
								{#if !definition.retiredAt}
									<DropdownMenu.Root>
										<DropdownMenu.Trigger
											class={buttonVariants({
												variant: "ghost",
												size: "icon",
												class: "sm:hidden",
											})}
											aria-label="Property actions for {definition.label}"
										>
											<Ellipsis aria-hidden="true" />
										</DropdownMenu.Trigger>
										<DropdownMenu.Content align="end" class="w-44 sm:hidden">
											<DropdownMenu.Item
												onSelect={() => editDefinition(definition)}
											>
												<Pencil />Edit property
											</DropdownMenu.Item>
											<DropdownMenu.Separator />
											<DropdownMenu.Item
												class="text-destructive focus:text-destructive"
												onSelect={() =>
													definitionRetire.mutate({
														path: { id: definition.id },
													})}
											>
												<Trash2 />Retire property
											</DropdownMenu.Item>
										</DropdownMenu.Content>
									</DropdownMenu.Root>
									<div class="hidden gap-2 sm:flex">
										<Button
											size="sm"
											variant="outline"
											onclick={() => editDefinition(definition)}
											><Pencil />Edit property</Button
										>
										<Button
											size="sm"
											variant="ghost"
											class="text-destructive hover:bg-destructive/10 hover:text-destructive"
											onclick={() =>
												definitionRetire.mutate({
													path: { id: definition.id },
												})}>Retire property</Button
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
										<Badge variant="outline">
											{formatCount(
												definition.options.filter((option) => !option.retiredAt)
													.length,
												"active option",
												"active options",
											)}
										</Badge>
									</div>
									<div class="space-y-2">
										{#each definition.options as option (option.id)}
											{@const draft = optionDraft(option)}
											{#if editingOptionId === option.id}
												{@const optionUpdateForm = updateOption.for(option.id)}
												<form
													{...optionUpdateForm.enhance(async (form) => {
														if (await form.submit())
															handleOptionUpdate(form.result);
													})}
													class="grid gap-2 rounded-xl border border-primary/35 bg-background p-3 sm:grid-cols-[minmax(0,1fr)_6rem_auto] sm:items-center"
												>
													<input
														type="hidden"
														name={optionUpdateForm.fields.optionId.as(
															"hidden",
															option.id,
														).name}
														value={option.id}
													/>
													{#each optionUpdateForm.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
															role="alert"
															class="text-sm text-destructive sm:col-span-3"
														>
															{issue.message}
														</p>{/each}
													{#if optionUpdateForm.result && !optionUpdateForm.result.ok}<p
															role="alert"
															class="text-sm text-destructive sm:col-span-3"
														>
															{optionUpdateForm.result.error}
														</p>{/if}
													<Input
														name={optionUpdateForm.fields.label.as("text").name}
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
															name={optionUpdateForm.fields.position.as("text")
																.name}
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
														<SubmitButton
															size="sm"
															type="submit"
															pending={optionUpdateForm.pending > 0}
															pendingLabel="Saving…"
														>
															Save
														</SubmitButton>
														<Button
															size="sm"
															variant="ghost"
															type="button"
															onclick={() => cancelOptionEdit(option.id)}
															>Cancel</Button
														>
													</div>
												</form>
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
														<DropdownMenu.Root>
															<DropdownMenu.Trigger
																class={buttonVariants({
																	variant: "ghost",
																	size: "icon",
																	class: "sm:hidden",
																})}
																aria-label="Option actions for {option.label}"
															>
																<Ellipsis aria-hidden="true" />
															</DropdownMenu.Trigger>
															<DropdownMenu.Content
																align="end"
																class="w-40 sm:hidden"
															>
																<DropdownMenu.Item
																	onSelect={() => editOption(option)}
																>
																	<Pencil />Edit option
																</DropdownMenu.Item>
																<DropdownMenu.Separator />
																<DropdownMenu.Item
																	class="text-destructive focus:text-destructive"
																	onSelect={() =>
																		optionRetire.mutate({
																			path: { id: option.id },
																		})}
																>
																	<Trash2 />Retire option
																</DropdownMenu.Item>
															</DropdownMenu.Content>
														</DropdownMenu.Root>
														<div class="hidden gap-1 sm:flex">
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
										{@const optionForm = createOption.for(definition.id)}
										<form
											{...optionForm.enhance(async (form) => {
												if (
													(await form.submit()) &&
													handleOptionCreate(form.result)
												)
													form.element.reset();
											})}
											class="mt-3 flex gap-2 rounded-xl border border-dashed bg-background/70 p-2.5"
										>
											<input
												type="hidden"
												name={optionForm.fields.definitionId.as(
													"hidden",
													definition.id,
												).name}
												value={definition.id}
											/>
											{#each optionForm.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<span
													role="alert"
													class="self-center text-sm text-destructive"
													>{issue.message}</span
												>{/each}
											{#if optionForm.result && !optionForm.result.ok}<span
													role="alert"
													class="self-center text-sm text-destructive"
													>{optionForm.result.error}</span
												>{/if}
											<Input
												name={optionForm.fields.label.as("text").name}
												class="h-11"
												maxlength={100}
												aria-label="New option label"
												placeholder="Add another option"
												required
											/>
											<SubmitButton
												type="submit"
												size="sm"
												class="min-h-11"
												pending={optionForm.pending > 0}
												pendingLabel="Adding…"
											>
												<Plus />Add
											</SubmitButton>
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
			{:else if selectedCategoryId && categoriesQuery.isPending}
				<div
					class="inventory-panel grid min-h-48 place-items-center border-dashed p-8 text-center"
					aria-live="polite"
				>
					<p class="text-sm text-muted-foreground">Loading category…</p>
				</div>
			{:else if selectedCategoryId}
				<div
					class="inventory-panel grid min-h-64 place-items-center border-dashed p-8 text-center"
				>
					<div class="max-w-md">
						<h2 class="font-heading text-2xl font-bold">Category not found</h2>
						<p class="mt-2 text-sm leading-relaxed text-muted-foreground">
							This category may have been deleted or the link may be out of
							date.
						</p>
						<Button href={LIST_PATH} variant="outline" class="mt-5">
							<ArrowLeft aria-hidden="true" />
							Back to categories
						</Button>
					</div>
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
							Select a category to edit its labels, required details, and
							options.
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
			{...saveCategory.enhance(async (form) => {
				if (await form.submit()) handleCategorySave(form.result);
			})}
			class="flex min-h-0 flex-1 flex-col"
		>
			<input
				type="hidden"
				name={saveCategory.fields.id.as("hidden", editingCategory?.id ?? "")
					.name}
				value={editingCategory?.id ?? ""}
			/>
			{#each saveCategory.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
					role="alert"
					class="mx-5 mt-4 text-sm text-destructive sm:mx-6"
				>
					{issue.message}
				</p>{/each}
			{#if saveCategory.result && !saveCategory.result.ok}<p
					role="alert"
					class="mx-5 mt-4 text-sm text-destructive sm:mx-6"
				>
					{saveCategory.result.error}
				</p>{/if}
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
							name={saveCategory.fields.name.as("text").name}
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
							name={saveCategory.fields.description.as("text").name}
							bind:value={categoryDescription}
						/>
						<p class="mt-2 text-xs leading-relaxed text-muted-foreground">
							A short description of what belongs here, so gear is categorised
							the same way next time.
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
				<SubmitButton
					type="submit"
					class="flex-1"
					disabled={saveCategory.pending > 0}
					pending={saveCategory.pending > 0}
					succeeded={categorySucceeded}
					pendingLabel={editingCategory ? "Saving…" : "Adding…"}
					successLabel={editingCategory ? "Saved" : "Added"}
				>
					{editingCategory ? "Save" : "Add category"}
				</SubmitButton>
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
