<script lang="ts">
import { onDestroy } from "svelte";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import {
	createMutation,
	createQuery,
	keepPreviousData,
	useQueryClient,
} from "@tanstack/svelte-query";
import {
	type InventoryOperatorItem,
	type InventoryOperatorItemValues,
	type InventoryPropertyDefinition,
	inventoryCategoriesIndexOptions,
	inventoryContainersIndexOptions,
	inventoryItemsArchiveMutation,
	inventoryItemsDeleteMutation,
	inventoryItemsListMaintenanceOptions,
	inventoryItemsListOptions,
	inventoryItemsRestoreMutation,
	inventoryItemsShowOptions,
	inventoryStructureListDefinitionsOptions,
} from "@dhc/api-client";
import {
	changeItemCategory,
	createItem,
	endItemMaintenance,
	moveItem,
	startItemMaintenance,
	updateItem,
} from "./data.remote";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import * as AlertDialog from "$lib/components/ui/alert-dialog";
import { Badge } from "$lib/components/ui/badge";
import { Button, buttonVariants } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as Select from "$lib/components/ui/select";
import * as Sheet from "$lib/components/ui/sheet";
import * as Tabs from "$lib/components/ui/tabs";
import { Textarea } from "$lib/components/ui/textarea";
import InventoryPageHeader from "$lib/components/inventory/InventoryPageHeader.svelte";
import { apiErrorMessage } from "$lib/api-error";
import {
	Archive,
	ArrowLeft,
	LoaderCircle,
	MapPin,
	NotebookPen,
	PackageSearch,
	PackagePlus,
	RefreshCw,
	RotateCcw,
	SlidersHorizontal,
	Tags,
	Trash2,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";

const PAGE_SIZE = 25;
const LIST_PATH = "/dashboard/inventory/items";
const selectedItemId = $derived(page.params.itemId);
const creatingItem = $derived(selectedItemId === "new");

let archived = $state<"exclude" | "include" | "only">("exclude");
let availability = $state<"all" | "maintenance">("all");
let search = $state("");
let debouncedQuery = $state("");
let searchTimeout: ReturnType<typeof setTimeout> | undefined;
let cursor = $state<string | undefined>(undefined);
let slugLookup = $state(page.url.searchParams.get("slug") ?? "");
let lookedUpSlug = $state<string | undefined>(undefined);
const queryClient = useQueryClient();
let categoryId = $state("");
let containerId = $state("");
let notes = $state("");
let values = $state<InventoryOperatorItemValues>({});
let selected = $state<InventoryOperatorItem | undefined>();
let editNotes = $state("");
let editValues = $state<InventoryOperatorItemValues>({});
let moveContainerId = $state("");
let newCategoryId = $state("");
let newCategoryValues = $state<InventoryOperatorItemValues>({});
let maintenanceReason = $state("");
let maintenanceEndNote = $state("");
let archiveReason = $state("");
type ManagementTab = "details" | "placement" | "maintenance";
let managementTab = $state<ManagementTab>("details");
let deleteConfirmOpen = $state(false);
let mobileFiltersOpen = $state(false);

const availabilityOptions = [
	{ value: "all", label: "All states" },
	{ value: "maintenance", label: "Maintenance" },
];
const archiveOptions = [
	{ value: "exclude", label: "Active" },
	{ value: "include", label: "All" },
	{ value: "only", label: "Archived" },
];

const itemsQuery = createQuery(() => ({
	...inventoryItemsListOptions({
		query: {
			archived,
			limit: PAGE_SIZE,
			q: debouncedQuery || undefined,
			cursor,
		},
	}),
	placeholderData: keepPreviousData,
	select: (response) => response.data,
}));
const routedItemQuery = createQuery(() => ({
	...inventoryItemsShowOptions({ path: { slugOrId: selectedItemId ?? "" } }),
	enabled: Boolean(selectedItemId && selectedItemId !== "new"),
	select: (response) => response.data,
}));
const categoriesQuery = createQuery(() => ({
	...inventoryCategoriesIndexOptions(),
	select: (response) => response.data.categories,
}));
const containersQuery = createQuery(() => ({
	...inventoryContainersIndexOptions(),
	select: (response) => response.data.containers,
}));
const definitionsQuery = createQuery(() => ({
	...inventoryStructureListDefinitionsOptions({ path: { categoryId } }),
	enabled: Boolean(categoryId),
	select: (response) => response.data.definitions,
}));
const editDefinitionsQuery = createQuery(() => ({
	...inventoryStructureListDefinitionsOptions({
		path: { categoryId: selected?.categoryId ?? "" },
	}),
	enabled: Boolean(selected),
	select: (response) => response.data.definitions,
}));
const newDefinitionsQuery = createQuery(() => ({
	...inventoryStructureListDefinitionsOptions({
		path: { categoryId: newCategoryId },
	}),
	enabled: Boolean(newCategoryId),
	select: (response) => response.data.definitions,
}));
const maintenanceQuery = createQuery(() => ({
	...inventoryItemsListMaintenanceOptions({
		path: { slugOrId: selected?.slug ?? "" },
	}),
	enabled: Boolean(selected),
	select: (response) => response.data.periods,
}));
const maintenanceItems = $derived(
	(itemsQuery.data?.items ?? []).filter(
		(item) => item.availability.status === "maintenance",
	),
);
const categoryOptions = $derived(
	(categoriesQuery.data ?? []).map((category) => ({
		value: category.id,
		label: category.name,
	})),
);
const containerOptions = $derived(
	(containersQuery.data ?? [])
		.filter((container) => !container.archivedAt)
		.map((container) => ({ value: container.id, label: container.name })),
);
const visibleItems = $derived(
	availability === "maintenance"
		? maintenanceItems
		: (itemsQuery.data?.items ?? []),
);
const activeFilterCount = $derived(
	Number(availability !== "all") + Number(archived !== "exclude"),
);
const detailsDirty = $derived(
	Boolean(
		selected &&
		(editNotes.trim() !== (selected.notes ?? "") ||
			JSON.stringify(editValues) !== JSON.stringify(itemValues(selected))),
	),
);
const placementDirty = $derived(
	Boolean(selected && moveContainerId !== (selected.containerId ?? "")),
);
const categoryDirty = $derived(
	Boolean(
		selected &&
		(newCategoryId !== selected.categoryId ||
			JSON.stringify(newCategoryValues) !==
				JSON.stringify(itemValues(selected))),
	),
);

function refresh() {
	void itemsQuery.refetch();
	void maintenanceQuery.refetch();
}
function updateSearch(value: string) {
	search = value;
	clearTimeout(searchTimeout);
	searchTimeout = setTimeout(() => {
		debouncedQuery = value.trim();
		cursor = undefined;
	}, 300);
}
function openMobileFilters() {
	mobileFiltersOpen = true;
}
function clearMobileFilters() {
	availability = "all";
	archived = "exclude";
	cursor = undefined;
}
async function lookupSlug(slug: string) {
	const trimmed = slug.trim();
	if (!trimmed) return;
	try {
		const response = await queryClient.fetchQuery(
			inventoryItemsShowOptions({ path: { slugOrId: trimmed } }),
		);
		await goto(`${LIST_PATH}/${response.data.slug}`);
	} catch (cause) {
		toast.error(apiErrorMessage(cause, "No item matches that code"));
	}
}
$effect(() => {
	const slug = page.url.searchParams.get("slug")?.trim();
	if (!slug || slug === lookedUpSlug) return;
	lookedUpSlug = slug;
	slugLookup = slug;
	void lookupSlug(slug);
});
$effect(() => {
	if (!selectedItemId || creatingItem) {
		selected = undefined;
		return;
	}
	if (routedItemQuery.data && routedItemQuery.data.slug !== selected?.slug) {
		choose(routedItemQuery.data);
	}
});
onDestroy(() => clearTimeout(searchTimeout));
function itemValues(item: InventoryOperatorItem): InventoryOperatorItemValues {
	return Object.fromEntries(
		item.values.map((value) => [
			value.definitionId,
			value.text ?? value.decimal ?? value.boolean ?? value.optionId,
		]),
	);
}
function choose(
	item: InventoryOperatorItem,
	tab: ManagementTab = "details",
	resetTransientFields = true,
) {
	selected = item;
	managementTab = tab;
	editNotes = item.notes ?? "";
	editValues = itemValues(item);
	moveContainerId = item.containerId ?? "";
	newCategoryId = item.categoryId;
	newCategoryValues = itemValues(item);
	if (resetTransientFields) {
		maintenanceReason = "";
		maintenanceEndNote = "";
		archiveReason = "";
	}
	deleteConfirmOpen = false;
}
function resetCreate() {
	categoryId = "";
	containerId = "";
	notes = "";
	values = {};
}
function commandOptions(success: string, fallback: string, after?: () => void) {
	return {
		onSuccess: (response: { data: InventoryOperatorItem }) => {
			toast.success(success);
			if (selected) choose(response.data, managementTab, false);
			after?.();
			refresh();
		},
		onError: apiErrorHandler(fallback),
	};
}
function apiErrorHandler(fallback: string) {
	return (cause: unknown) => toast.error(apiErrorMessage(cause, fallback));
}
const archiveItem = createMutation(() => ({
	...inventoryItemsArchiveMutation(),
	...commandOptions("Item archived", "Could not archive item"),
}));
const restoreItem = createMutation(() => ({
	...inventoryItemsRestoreMutation(),
	...commandOptions("Item restored", "Could not restore item"),
}));
const deleteItem = createMutation(() => ({
	...inventoryItemsDeleteMutation(),
	onSuccess: () => {
		toast.success("Item deleted");
		deleteConfirmOpen = false;
		selected = undefined;
		refresh();
		void goto(LIST_PATH);
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Items with history must be archived")),
}));

function handleCreateItem(result: typeof createItem.result) {
	if (!result) return;
	if (!result.ok) return toast.error(result.error);
	toast.success("Item created");
	resetCreate();
	refresh();
	void goto(`${LIST_PATH}/${result.data.slug}`);
}

function handleItemCommand(
	result:
		| typeof updateItem.result
		| typeof moveItem.result
		| typeof changeItemCategory.result
		| typeof startItemMaintenance.result
		| typeof endItemMaintenance.result,
	success: string,
) {
	if (!result) return;
	if (!result.ok) return toast.error(result.error);
	toast.success(success);
	choose(result.data, managementTab, false);
	refresh();
}

function setValue(
	target: InventoryOperatorItemValues,
	id: string,
	value: string | boolean,
) {
	target[id] = value === "" ? null : value;
}
function displayValue(item: InventoryOperatorItem) {
	return item.values
		.map(
			(value) =>
				`${value.definitionLabel}: ${value.optionLabel ?? value.text ?? value.decimal ?? String(value.boolean)}`,
		)
		.join(" · ");
}
</script>

{#snippet fields(
	definitions: InventoryPropertyDefinition[],
	target: InventoryOperatorItemValues,
	prefix: string,
)}
	{#each definitions.filter((definition) => !definition.retiredAt) as definition (definition.id)}
		<div>
			<Label for={`${prefix}-${definition.id}`} class="mb-2.5">
				{definition.label}{#if definition.required}<span
						class="ml-1 text-xs font-normal text-muted-foreground"
						>(required)</span
					>{/if}
			</Label>
			{#if definition.valueType === "boolean"}
				<Select.Root
					type="single"
					bind:value={
						() =>
							target[definition.id] === true
								? "true"
								: target[definition.id] === false
									? "false"
									: "",
						(value) =>
							setValue(
								target,
								definition.id,
								value === "" ? "" : value === "true",
							)
					}
					required={definition.required}
				>
					<Select.Trigger
						id={`${prefix}-${definition.id}`}
						class="w-full data-[size=default]:h-11"
					>
						{target[definition.id] === true
							? "Yes"
							: target[definition.id] === false
								? "No"
								: "Not set"}
					</Select.Trigger>
					<Select.Content portalProps={{ disabled: true }}>
						<Select.Item value="true" label="Yes">Yes</Select.Item>
						<Select.Item value="false" label="No">No</Select.Item>
					</Select.Content>
				</Select.Root>
			{:else if definition.valueType === "single_select"}
				{@const activeOptions = definition.options.filter(
					(option) => !option.retiredAt,
				)}
				<Select.Root
					type="single"
					bind:value={
						() => String(target[definition.id] ?? ""),
						(value) => setValue(target, definition.id, value)
					}
					required={definition.required}
				>
					<Select.Trigger
						id={`${prefix}-${definition.id}`}
						class="w-full data-[size=default]:h-11"
					>
						{activeOptions.find(
							(option) => option.id === String(target[definition.id] ?? ""),
						)?.label ?? "Choose"}
					</Select.Trigger>
					<Select.Content portalProps={{ disabled: true }}>
						{#each activeOptions as option (option.id)}
							<Select.Item value={option.id} label={option.label}>
								{option.label}
							</Select.Item>
						{/each}
					</Select.Content>
				</Select.Root>
			{:else}
				<Input
					id={`${prefix}-${definition.id}`}
					type={definition.valueType === "decimal" ? "number" : "text"}
					step={definition.valueType === "decimal" ? "any" : undefined}
					value={String(target[definition.id] ?? "")}
					oninput={(event) =>
						setValue(target, definition.id, event.currentTarget.value)}
					required={definition.required}
				/>
			{/if}
		</div>
	{/each}
{/snippet}

<svelte:head>
	<title
		>{creatingItem
			? "Add inventory item"
			: selected?.label
				? `${selected.label} | Inventory items`
				: "Inventory items"} | Dublin HEMA Club</title
	>
</svelte:head>

{#snippet createAction()}
	<Button href={`${LIST_PATH}/new`}>
		<PackagePlus aria-hidden="true" />New item
	</Button>
{/snippet}

<div
	class="inventory-page {selectedItemId && !creatingItem
		? 'space-y-4 xl:py-4'
		: 'xl:flex xl:h-[calc(100svh-2.8125rem)] xl:flex-col xl:space-y-4 xl:overflow-hidden xl:py-4'} {selectedItemId
		? 'max-lg:max-w-none max-lg:space-y-0 max-lg:px-0 max-lg:py-0'
		: ''}"
>
	<InventoryPageHeader
		eyebrow="Quartermaster"
		title="Items"
		icon={PackageSearch}
		actions={selectedItemId ? undefined : createAction}
		class="flex-row items-end justify-between xl:pb-3 {selectedItemId
			? 'max-lg:hidden'
			: ''}"
	/>
	{#if itemsQuery.isError}<Alert variant="destructive"
			><AlertDescription class="flex items-center justify-between"
				><span>{apiErrorMessage(itemsQuery.error, "Could not load items")}</span
				><Button
					variant="outline"
					size="sm"
					onclick={() => itemsQuery.refetch()}><RefreshCw />Try again</Button
				></AlertDescription
			></Alert
		>{/if}
	<div class="min-h-0 xl:flex-1">
		{#if creatingItem}
			<section
				class="mx-auto flex h-full min-h-0 max-w-4xl flex-col overflow-hidden rounded-2xl border bg-background shadow-sm max-lg:min-h-[calc(100svh-2.8125rem)] max-lg:rounded-none max-lg:border-x-0 max-lg:shadow-none max-lg:animate-in max-lg:fade-in-0 max-lg:slide-in-from-right-4 max-lg:duration-200 max-lg:motion-reduce:animate-none"
			>
				<div class="shrink-0 border-b px-3 py-2 sm:px-5">
					<Button href={LIST_PATH} variant="ghost" class="min-h-11 px-2">
						<ArrowLeft aria-hidden="true" />All items
					</Button>
				</div>
				<form
					{...createItem.enhance(async (form) => {
						if (await form.submit()) handleCreateItem(form.result);
					})}
					aria-busy={createItem.pending > 0}
					class="flex min-h-0 flex-1 flex-col"
				>
					<input
						type="hidden"
						name={createItem.fields.categoryId.as("hidden", categoryId).name}
						value={categoryId}
					/>
					<input
						type="hidden"
						name={createItem.fields.containerId.as("hidden", containerId).name}
						value={containerId}
					/>
					<input
						type="hidden"
						name={createItem.fields.values.as("hidden", JSON.stringify(values))
							.name}
						value={JSON.stringify(values)}
					/>
					{#each createItem.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
							role="alert"
							class="mx-5 mt-4 text-sm text-destructive sm:mx-8"
						>
							{issue.message}
						</p>{/each}
					{#if createItem.result && !createItem.result.ok}<p
							role="alert"
							class="mx-5 mt-4 text-sm text-destructive sm:mx-8"
						>
							{createItem.result.error}
						</p>{/if}
					<div
						class="shrink-0 border-b bg-primary/7 px-5 pt-[max(1.25rem,env(safe-area-inset-top))] pr-16 pb-5 text-left sm:px-6 sm:pt-6"
					>
						<div class="flex items-start gap-3">
							<div
								class="grid size-11 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm"
							>
								<PackagePlus class="size-5" aria-hidden="true" />
							</div>
							<div>
								<p
									class="text-[0.68rem] font-bold tracking-[0.16em] text-primary uppercase"
								>
									New item
								</p>
								<h2 class="font-heading text-2xl font-bold">Add item</h2>
								<p class="mt-1 text-sm leading-relaxed text-muted-foreground">
									The label and permanent item code are generated for you.
								</p>
							</div>
						</div>
					</div>

					<div
						class="min-h-0 flex-1 space-y-6 overflow-y-auto overscroll-contain bg-muted/20 p-5 sm:p-8"
					>
						<fieldset
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm sm:p-6"
						>
							<legend class="sr-only">What and where</legend>
							<div class="flex items-start gap-3 border-b pb-4">
								<span
									class="grid size-8 shrink-0 place-items-center rounded-full bg-secondary text-sm font-bold text-secondary-foreground"
									>1</span
								>
								<div>
									<h3 class="font-heading text-lg font-bold">What and where</h3>
									<p class="mt-0.5 text-sm text-muted-foreground">
										Choose what it is and where it's stored.
									</p>
								</div>
							</div>
							<div class="grid gap-5 sm:grid-cols-2 sm:gap-6">
								<div>
									<Label
										for="item-category"
										class="mb-2.5 flex items-center gap-1.5"
										><Tags
											class="size-3.5 text-primary"
											aria-hidden="true"
										/>Category</Label
									>
									<span class="mb-2 block text-xs text-muted-foreground"
										>Required</span
									>
									<Select.Root
										type="single"
										items={categoryOptions}
										bind:value={categoryId}
										onValueChange={() => (values = {})}
										required
									>
										<Select.Trigger
											id="item-category"
											class="w-full data-[size=default]:h-11"
										>
											{categoryOptions.find(
												(option) => option.value === categoryId,
											)?.label ?? "Choose category"}
										</Select.Trigger>
										<Select.Content portalProps={{ disabled: true }}>
											{#each categoryOptions as option (option.value)}
												<Select.Item value={option.value} label={option.label}>
													{option.label}
												</Select.Item>
											{/each}
										</Select.Content>
									</Select.Root>
								</div>
								<div>
									<Label
										for="item-container"
										class="mb-2.5 flex items-center gap-1.5"
										><MapPin
											class="size-3.5 text-primary"
											aria-hidden="true"
										/>Container</Label
									>
									<span class="mb-2 block text-xs text-muted-foreground"
										>Required</span
									>
									<Select.Root
										type="single"
										items={containerOptions}
										bind:value={containerId}
										required
									>
										<Select.Trigger
											id="item-container"
											class="w-full data-[size=default]:h-11"
										>
											{containerOptions.find(
												(option) => option.value === containerId,
											)?.label ?? "Choose container"}
										</Select.Trigger>
										<Select.Content portalProps={{ disabled: true }}>
											{#each containerOptions as option (option.value)}
												<Select.Item value={option.value} label={option.label}>
													{option.label}
												</Select.Item>
											{/each}
										</Select.Content>
									</Select.Root>
								</div>
							</div>
						</fieldset>

						<fieldset
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm sm:p-6"
						>
							<legend class="sr-only">Details</legend>
							<div class="flex items-start gap-3 border-b pb-4">
								<span
									class="grid size-8 shrink-0 place-items-center rounded-full bg-secondary text-sm font-bold text-secondary-foreground"
									>2</span
								>
								<div>
									<h3 class="font-heading text-lg font-bold">Details</h3>
									<p class="mt-0.5 text-sm text-muted-foreground">
										Record size, condition, and any notes.
									</p>
								</div>
							</div>
							{#if categoryId && definitionsQuery.isPending}
								<div
									class="flex items-center gap-2 rounded-xl border border-dashed bg-muted/35 p-3 text-sm text-muted-foreground"
									aria-live="polite"
								>
									<LoaderCircle
										class="size-4 animate-spin motion-reduce:animate-none"
										aria-hidden="true"
									/>
									Loading category details…
								</div>
							{:else if categoryId}
								{@render fields(definitionsQuery.data ?? [], values, "create")}
							{:else}
								<p
									class="rounded-xl border border-dashed bg-muted/35 p-3 text-xs leading-relaxed text-muted-foreground"
								>
									Choose a category to reveal its specific properties.
								</p>
							{/if}
							<div>
								<Label for="item-notes" class="mb-2.5 flex items-center gap-1.5"
									><NotebookPen
										class="size-3.5 text-primary"
										aria-hidden="true"
									/>Notes</Label
								><Textarea
									id="item-notes"
									name={createItem.fields.notes.as("text").name}
									bind:value={notes}
								/>
								<p class="mt-1.5 text-xs text-muted-foreground">
									Optional notes for whoever handles this next.
								</p>
							</div>
						</fieldset>
					</div>

					<div
						class="shrink-0 border-t bg-background p-4 sm:flex-row sm:justify-between sm:px-6"
					>
						<div
							class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-between"
						>
							<Button href={LIST_PATH} variant="outline">Cancel</Button>
							<Button
								type="submit"
								class="min-h-11 sm:min-w-36"
								disabled={!categoryId ||
									!containerId ||
									createItem.pending > 0 ||
									definitionsQuery.isPending}
								><PackagePlus />{createItem.pending > 0
									? "Adding item…"
									: "Add item"}</Button
							>
						</div>
					</div>
				</form>
			</section>
		{:else if !selectedItemId}
			<section class="min-h-0 space-y-3 xl:flex xl:h-full xl:flex-col">
				<div class="flex items-center justify-between gap-3 lg:hidden">
					<div class="flex min-w-0 items-baseline gap-2">
						<h2 class="font-heading text-xl font-bold">All items</h2>
						<span class="text-sm text-muted-foreground"
							>{itemsQuery.data?.totalCount ?? 0} items</span
						>
					</div>
				</div>
				<div
					class="sticky top-[2.8125rem] z-10 -mx-4 flex gap-2 border-y border-border/70 bg-background/95 px-4 py-3 shadow-sm backdrop-blur-md sm:-mx-6 sm:px-6 lg:hidden"
				>
					<Label for="mobile-item-search" class="sr-only">Search items</Label>
					<Input
						id="mobile-item-search"
						type="search"
						class="h-11 flex-1 border-border bg-background shadow-xs"
						placeholder="Search code, name, location or notes"
						value={search}
						oninput={(event) => updateSearch(event.currentTarget.value)}
					/>
					<Button
						variant="outline"
						size="icon"
						class="relative size-11 shrink-0"
						aria-label={activeFilterCount > 0
							? `Filters, ${activeFilterCount} active`
							: "Filters"}
						onclick={openMobileFilters}
					>
						<SlidersHorizontal aria-hidden="true" />
						{#if activeFilterCount > 0}
							<span
								class="absolute -right-1.5 -top-1.5 grid size-5 place-items-center rounded-full bg-secondary text-[0.6875rem] font-bold text-secondary-foreground"
								aria-hidden="true"
							>
								{activeFilterCount}
							</span>
						{/if}
					</Button>
				</div>
				<div
					class="inventory-panel hidden flex-wrap items-end justify-between gap-4 p-4 lg:flex"
				>
					<div>
						<h2 class="text-lg font-semibold">All items</h2>
						<p class="text-sm text-muted-foreground">
							{itemsQuery.data?.totalCount ?? 0} items
						</p>
					</div>
					<div class="flex flex-1 flex-wrap items-end justify-end gap-3">
						<div class="min-w-56 flex-1 sm:max-w-80">
							<Label for="item-search" class="mb-2 text-xs font-semibold"
								>Search</Label
							>
							<Input
								id="item-search"
								type="search"
								class="h-11 border-border bg-background shadow-xs"
								placeholder="Code, name, location or notes"
								value={search}
								oninput={(event) => updateSearch(event.currentTarget.value)}
							/>
						</div>
						<form
							class="min-w-48 flex-1 sm:max-w-64"
							onsubmit={(event) => {
								event.preventDefault();
								void lookupSlug(slugLookup);
							}}
						>
							<Label for="item-slug-lookup" class="mb-2 text-xs font-semibold"
								>Find by code</Label
							>
							<div class="flex gap-2">
								<Input
									id="item-slug-lookup"
									data-testid="find-by-slug"
									class="h-11 border-border bg-background shadow-xs"
									placeholder="item-000001"
									bind:value={slugLookup}
								/>
								<Button type="submit" variant="outline" class="h-11">
									Find
								</Button>
							</div>
						</form>
						<div>
							<Label
								for="availability-filter"
								class="mb-2 text-xs font-semibold">Availability</Label
							>
							<Select.Root
								type="single"
								items={availabilityOptions}
								bind:value={availability}
							>
								<Select.Trigger
									id="availability-filter"
									class="min-w-36 data-[size=default]:h-11"
								>
									{availabilityOptions.find(
										(option) => option.value === availability,
									)?.label}
								</Select.Trigger>
								<Select.Content>
									{#each availabilityOptions as option (option.value)}
										<Select.Item value={option.value} label={option.label}>
											{option.label}
										</Select.Item>
									{/each}
								</Select.Content>
							</Select.Root>
						</div>
						<div>
							<Label for="archive-filter" class="mb-2 text-xs font-semibold"
								>Archive filter</Label
							>
							<Select.Root
								type="single"
								items={archiveOptions}
								bind:value={archived}
								onValueChange={() => (cursor = undefined)}
							>
								<Select.Trigger
									id="archive-filter"
									class="min-w-32 data-[size=default]:h-11"
								>
									{archiveOptions.find((option) => option.value === archived)
										?.label}
								</Select.Trigger>
								<Select.Content>
									{#each archiveOptions as option (option.value)}
										<Select.Item value={option.value} label={option.label}>
											{option.label}
										</Select.Item>
									{/each}
								</Select.Content>
							</Select.Root>
						</div>
					</div>
				</div>
				<div
					class="space-y-3 xl:min-h-0 xl:overflow-y-auto xl:overscroll-contain xl:pr-2 xl:[scrollbar-gutter:stable]"
				>
					{#each visibleItems as item (item.id)}<article
							class="inventory-card p-4 {item.archivedAt ? 'opacity-65' : ''}"
						>
							<div class="flex flex-wrap items-start justify-between gap-3">
								<div>
									<div class="flex flex-wrap items-center gap-2">
										<h3 class="font-semibold">{item.label}</h3>
										<Badge variant="outline">{item.slug}</Badge><Badge
											variant={item.availability.available
												? "secondary"
												: "outline"}
											>{item.availability.status
												.replace("_", " ")
												.replace(/^./, (character) =>
													character.toUpperCase(),
												)}</Badge
										>
									</div>
									<p class="mt-1 text-sm text-muted-foreground">
										{item.category?.name} · {item.container?.name ??
											"No container"}
									</p>
									{#if item.values.length}<p class="mt-1 text-sm">
											{displayValue(item)}
										</p>{/if}{#if item.notes}<p class="mt-1 text-sm">
											{item.notes}
										</p>{/if}
								</div>
								<Button
									size="sm"
									variant="outline"
									href={`${LIST_PATH}/${item.slug}`}>Manage</Button
								>
							</div>
						</article>{:else}<div
							class="rounded-2xl border bg-card p-10 text-center"
						>
							<h2 class="font-semibold">No items found</h2>
							<p class="text-sm text-muted-foreground">
								{debouncedQuery
									? "Try another search or change the filters."
									: "Add an item or change the archive filter."}
							</p>
						</div>{/each}
					{#if cursor || itemsQuery.data?.nextCursor}
						<div class="flex items-center justify-between gap-2">
							{#if itemsQuery.data?.previousCursor}
								<Button
									variant="outline"
									size="sm"
									class="min-h-11"
									data-testid="items-previous-page"
									onclick={() => {
										cursor = itemsQuery.data?.previousCursor ?? undefined;
									}}
								>
									Previous
								</Button>
							{:else}
								<span></span>
							{/if}
							{#if itemsQuery.data?.nextCursor}
								<Button
									variant="outline"
									size="sm"
									class="min-h-11"
									data-testid="items-next-page"
									onclick={() => {
										cursor = itemsQuery.data?.nextCursor ?? undefined;
									}}
								>
									Next
								</Button>
							{/if}
						</div>
					{/if}
				</div>
			</section>
		{:else if routedItemQuery.isError}
			<Alert variant="destructive" class="mx-auto max-w-5xl">
				<AlertDescription class="flex items-center justify-between gap-4">
					<span
						>{apiErrorMessage(
							routedItemQuery.error,
							"Could not load item",
						)}</span
					>
					<Button
						variant="outline"
						size="sm"
						onclick={() => routedItemQuery.refetch()}
					>
						<RefreshCw />Try again
					</Button>
				</AlertDescription>
			</Alert>
		{:else if routedItemQuery.isPending}
			<div
				class="mx-auto grid min-h-64 max-w-5xl place-items-center"
				aria-live="polite"
			>
				<p class="text-sm text-muted-foreground">Loading item…</p>
			</div>
		{/if}
	</div>
</div>

<Sheet.Root bind:open={mobileFiltersOpen}>
	<Sheet.Content
		side="bottom"
		class="max-h-[calc(100svh-1rem)] gap-0 overflow-hidden rounded-t-2xl p-0 lg:hidden"
	>
		<Sheet.Header class="shrink-0 border-b px-5 py-5 pr-16 text-left">
			<div class="flex items-center gap-3">
				<div
					class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary"
				>
					<SlidersHorizontal class="size-5" aria-hidden="true" />
				</div>
				<div>
					<Sheet.Title class="font-heading text-xl font-bold">
						Filter items
					</Sheet.Title>
					<Sheet.Description class="mt-0.5">
						Narrow the list by availability or archive status.
					</Sheet.Description>
				</div>
			</div>
		</Sheet.Header>

		<div class="min-h-0 flex-1 overflow-y-auto p-5">
			<fieldset class="space-y-4">
				<legend class="font-heading text-lg font-bold">List filters</legend>
				<div>
					<Label
						for="mobile-availability-filter"
						class="mb-2 text-sm font-semibold">Availability</Label
					>
					<Select.Root
						type="single"
						items={availabilityOptions}
						bind:value={availability}
					>
						<Select.Trigger
							id="mobile-availability-filter"
							class="w-full data-[size=default]:h-11"
						>
							{availabilityOptions.find(
								(option) => option.value === availability,
							)?.label}
						</Select.Trigger>
						<Select.Content>
							{#each availabilityOptions as option (option.value)}
								<Select.Item value={option.value} label={option.label}>
									{option.label}
								</Select.Item>
							{/each}
						</Select.Content>
					</Select.Root>
				</div>
				<div>
					<Label for="mobile-archive-filter" class="mb-2 text-sm font-semibold"
						>Archive filter</Label
					>
					<Select.Root
						type="single"
						items={archiveOptions}
						bind:value={archived}
						onValueChange={() => (cursor = undefined)}
					>
						<Select.Trigger
							id="mobile-archive-filter"
							class="w-full data-[size=default]:h-11"
						>
							{archiveOptions.find((option) => option.value === archived)
								?.label}
						</Select.Trigger>
						<Select.Content>
							{#each archiveOptions as option (option.value)}
								<Select.Item value={option.value} label={option.label}>
									{option.label}
								</Select.Item>
							{/each}
						</Select.Content>
					</Select.Root>
				</div>
			</fieldset>
		</div>

		<Sheet.Footer
			class="shrink-0 flex-row justify-between border-t bg-background p-4 pb-[max(1rem,env(safe-area-inset-bottom))]"
		>
			<Button
				variant="ghost"
				disabled={activeFilterCount === 0}
				onclick={clearMobileFilters}>Clear filters</Button
			>
			<Sheet.Close class={buttonVariants()}>Show items</Sheet.Close>
		</Sheet.Footer>
	</Sheet.Content>
</Sheet.Root>

{#if selected}
	<section
		class="inventory-page !pt-0 max-lg:max-w-none max-lg:px-0 max-lg:pb-0 max-lg:animate-in max-lg:fade-in-0 max-lg:slide-in-from-right-4 max-lg:duration-200 max-lg:motion-reduce:animate-none"
	>
		<div
			class="mx-auto flex min-h-[calc(100svh-12rem)] w-full max-w-5xl flex-col overflow-hidden rounded-2xl border bg-background shadow-sm max-lg:min-h-[calc(100svh-2.8125rem)] max-lg:rounded-none max-lg:border-x-0 max-lg:shadow-none"
		>
			<div class="shrink-0 border-b px-3 py-2 sm:px-5">
				<Button href={LIST_PATH} variant="ghost" class="min-h-11 px-2">
					<ArrowLeft aria-hidden="true" />All items
				</Button>
			</div>
			<div
				class="shrink-0 border-b bg-primary/7 px-5 pt-[max(1.25rem,env(safe-area-inset-top))] pr-16 pb-5 text-left sm:px-6 sm:pt-6"
			>
				<div class="flex items-start gap-3">
					<div
						class="grid size-11 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm"
					>
						<PackageSearch class="size-5" aria-hidden="true" />
					</div>
					<div class="min-w-0">
						<div class="flex flex-wrap items-center gap-2">
							<h2 class="font-heading text-2xl font-bold">
								{selected.label}
							</h2>
							<Badge
								variant={selected.availability.available
									? "secondary"
									: "outline"}
							>
								{selected.availability.status
									.replace("_", " ")
									.replace(/^./, (character) => character.toUpperCase())}
							</Badge>
						</div>
						<p class="mt-1 font-mono text-sm text-muted-foreground">
							{selected.slug}
						</p>
					</div>
				</div>
			</div>

			<Tabs.Root bind:value={managementTab} class="min-h-0 flex-1 gap-0">
				<div class="shrink-0 border-b bg-background px-5 py-3 sm:px-6">
					<Tabs.List class="grid h-11 w-full grid-cols-3">
						<Tabs.Trigger value="details">Details</Tabs.Trigger>
						<Tabs.Trigger value="placement">Placement</Tabs.Trigger>
						<Tabs.Trigger value="maintenance">Maintenance</Tabs.Trigger>
					</Tabs.List>
				</div>

				<Tabs.Content value="details" class="min-h-0 overflow-hidden">
					<form
						{...updateItem.enhance(async (form) => {
							if (await form.submit())
								handleItemCommand(form.result, "Item updated");
						})}
						aria-busy={updateItem.pending > 0}
						class="flex h-full min-h-0 flex-col"
					>
						<input
							type="hidden"
							name={updateItem.fields.slugOrId.as("hidden", selected.slug).name}
							value={selected.slug}
						/>
						<input
							type="hidden"
							name={updateItem.fields.values.as(
								"hidden",
								JSON.stringify(editValues),
							).name}
							value={JSON.stringify(editValues)}
						/>
						{#each updateItem.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
								role="alert"
								class="mx-5 mt-4 text-sm text-destructive sm:mx-6"
							>
								{issue.message}
							</p>{/each}
						{#if updateItem.result && !updateItem.result.ok}<p
								role="alert"
								class="mx-5 mt-4 text-sm text-destructive sm:mx-6"
							>
								{updateItem.result.error}
							</p>{/if}
						<div
							class="min-h-0 flex-1 space-y-6 overflow-y-auto bg-muted/20 p-5 sm:p-6"
						>
							<section
								class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
							>
								<div class="border-b pb-4">
									<h3 class="font-heading text-lg font-bold">Details</h3>
									<p class="mt-1 text-sm text-muted-foreground">
										Update properties and notes.
									</p>
								</div>
								{#if editDefinitionsQuery.isPending}
									<p class="text-sm text-muted-foreground" aria-live="polite">
										Loading item details…
									</p>
								{:else}
									{@render fields(
										editDefinitionsQuery.data ?? [],
										editValues,
										"edit",
									)}
								{/if}
								<div>
									<Label for="edit-notes" class="mb-2.5">Notes</Label>
									<Textarea
										id="edit-notes"
										name={updateItem.fields.notes.as("text").name}
										bind:value={editNotes}
									/>
								</div>
							</section>

							<section
								class="space-y-4 rounded-2xl border border-destructive/25 bg-destructive/3 p-5 shadow-sm"
							>
								<div>
									<h3 class="font-heading text-lg font-bold">
										Archive or delete
									</h3>
									<p class="mt-1 text-sm text-muted-foreground">
										Archive items you still need a record of. Delete only items
										with no history.
									</p>
								</div>
								{#if selected.archivedAt}
									<Button
										type="button"
										variant="outline"
										disabled={restoreItem.isPending}
										onclick={() =>
											restoreItem.mutate({
												path: { slugOrId: selected!.slug },
											})}
									>
										<RotateCcw />{restoreItem.isPending
											? "Restoring…"
											: "Restore item"}
									</Button>
								{:else}
									<div>
										<Label for="archive-reason" class="mb-2.5"
											>Archive note <span
												class="font-normal text-muted-foreground"
												>(optional)</span
											></Label
										>
										<Input id="archive-reason" bind:value={archiveReason} />
									</div>
									<div class="flex flex-wrap gap-2 border-t pt-4">
										<Button
											type="button"
											variant="outline"
											disabled={archiveItem.isPending}
											onclick={() =>
												archiveItem.mutate({
													path: { slugOrId: selected!.slug },
													body: { reason: archiveReason.trim() || null },
												})}
										>
											<Archive />{archiveItem.isPending
												? "Archiving…"
												: "Archive item"}
										</Button>
										<Button
											type="button"
											variant="destructive"
											disabled={archiveItem.isPending}
											onclick={() => (deleteConfirmOpen = true)}
										>
											<Trash2 />Delete item
										</Button>
									</div>
								{/if}
							</section>
						</div>
						<div
							class="shrink-0 border-t bg-background p-4 sm:flex sm:justify-end sm:px-6"
						>
							<Button
								type="submit"
								class="w-full sm:w-auto"
								disabled={!detailsDirty || updateItem.pending > 0}
							>
								{updateItem.pending > 0 ? "Saving…" : "Save changes"}
							</Button>
						</div>
					</form>
				</Tabs.Content>

				<Tabs.Content
					value="placement"
					class="min-h-0 overflow-y-auto bg-muted/20 p-5 sm:p-6"
				>
					<div class="space-y-6">
						<form
							{...moveItem.enhance(async (form) => {
								if (await form.submit())
									handleItemCommand(form.result, "Item moved");
							})}
							aria-busy={moveItem.pending > 0}
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
						>
							<input
								type="hidden"
								name={moveItem.fields.slugOrId.as("hidden", selected.slug).name}
								value={selected.slug}
							/>
							<input
								type="hidden"
								name={moveItem.fields.containerId.as("hidden", moveContainerId)
									.name}
								value={moveContainerId}
							/>
							{#each moveItem.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
									role="alert"
									class="text-sm text-destructive"
								>
									{issue.message}
								</p>{/each}
							{#if moveItem.result && !moveItem.result.ok}<p
									role="alert"
									class="text-sm text-destructive"
								>
									{moveItem.result.error}
								</p>{/if}
							<div class="border-b pb-4">
								<h3 class="font-heading text-lg font-bold">Move item</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Move it to a different container.
								</p>
							</div>
							<div>
								<Label for="move-container" class="mb-2.5"
									>Move to container</Label
								>
								<Select.Root
									type="single"
									items={containerOptions}
									bind:value={moveContainerId}
									required
								>
									<Select.Trigger
										id="move-container"
										class="w-full data-[size=default]:h-11"
									>
										{containerOptions.find(
											(option) => option.value === moveContainerId,
										)?.label ?? "Choose container"}
									</Select.Trigger>
									<Select.Content portalProps={{ disabled: true }}>
										{#each containerOptions as option (option.value)}
											<Select.Item value={option.value} label={option.label}>
												{option.label}
											</Select.Item>
										{/each}
									</Select.Content>
								</Select.Root>
								<p class="mt-2 text-xs text-muted-foreground">
									Current location: {selected.container?.name ?? "No container"}
								</p>
							</div>
							<Button
								type="submit"
								disabled={!placementDirty || moveItem.pending > 0}
								>{moveItem.pending > 0 ? "Moving…" : "Move item"}</Button
							>
						</form>

						<form
							{...changeItemCategory.enhance(async (form) => {
								if (await form.submit())
									handleItemCommand(form.result, "Category changed");
							})}
							aria-busy={changeItemCategory.pending > 0}
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
						>
							<input
								type="hidden"
								name={changeItemCategory.fields.slugOrId.as(
									"hidden",
									selected.slug,
								).name}
								value={selected.slug}
							/>
							<input
								type="hidden"
								name={changeItemCategory.fields.categoryId.as(
									"hidden",
									newCategoryId,
								).name}
								value={newCategoryId}
							/>
							<input
								type="hidden"
								name={changeItemCategory.fields.values.as(
									"hidden",
									JSON.stringify(newCategoryValues),
								).name}
								value={JSON.stringify(newCategoryValues)}
							/>
							{#each changeItemCategory.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
									role="alert"
									class="text-sm text-destructive"
								>
									{issue.message}
								</p>{/each}
							{#if changeItemCategory.result && !changeItemCategory.result.ok}<p
									role="alert"
									class="text-sm text-destructive"
								>
									{changeItemCategory.result.error}
								</p>{/if}
							<div class="border-b pb-4">
								<h3 class="font-heading text-lg font-bold">Change category</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Changing category replaces the details below.
								</p>
							</div>
							<div>
								<Label for="new-category" class="mb-2.5">New category</Label>
								<Select.Root
									type="single"
									items={categoryOptions}
									bind:value={newCategoryId}
									onValueChange={() => (newCategoryValues = {})}
									required
								>
									<Select.Trigger
										id="new-category"
										class="w-full data-[size=default]:h-11"
									>
										{categoryOptions.find(
											(option) => option.value === newCategoryId,
										)?.label ?? "Choose category"}
									</Select.Trigger>
									<Select.Content portalProps={{ disabled: true }}>
										{#each categoryOptions as option (option.value)}
											<Select.Item value={option.value} label={option.label}>
												{option.label}
											</Select.Item>
										{/each}
									</Select.Content>
								</Select.Root>
							</div>
							{#if newDefinitionsQuery.isPending}
								<p class="text-sm text-muted-foreground" aria-live="polite">
									Loading category details…
								</p>
							{:else}
								{@render fields(
									newDefinitionsQuery.data ?? [],
									newCategoryValues,
									"category",
								)}
							{/if}
							<Button
								type="submit"
								disabled={!categoryDirty ||
									newDefinitionsQuery.isPending ||
									changeItemCategory.pending > 0}
								>{changeItemCategory.pending > 0
									? "Saving category…"
									: "Save category"}</Button
							>
						</form>
					</div>
				</Tabs.Content>

				<Tabs.Content
					value="maintenance"
					class="min-h-0 overflow-y-auto bg-muted/20 p-5 sm:p-6"
				>
					<section class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm">
						<div class="border-b pb-4">
							<h3 class="font-heading text-lg font-bold">Maintenance</h3>
							<p class="mt-1 text-sm text-muted-foreground">
								Take the item out of circulation or return it when work is
								complete.
							</p>
						</div>
						{#if selected.availability.status === "maintenance"}
							<form
								{...endItemMaintenance.enhance(async (form) => {
									if (await form.submit())
										handleItemCommand(form.result, "Maintenance ended");
								})}
								class="space-y-4"
								aria-busy={endItemMaintenance.pending > 0}
							>
								<input
									type="hidden"
									name={endItemMaintenance.fields.slugOrId.as(
										"hidden",
										selected.slug,
									).name}
									value={selected.slug}
								/>
								{#each endItemMaintenance.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{issue.message}
									</p>{/each}
								{#if endItemMaintenance.result && !endItemMaintenance.result.ok}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{endItemMaintenance.result.error}
									</p>{/if}
								<div>
									<Label for="maintenance-end-note" class="mb-2.5"
										>Maintenance end note</Label
									>
									<Textarea
										id="maintenance-end-note"
										name={endItemMaintenance.fields.endNote.as("text").name}
										bind:value={maintenanceEndNote}
									/>
								</div>
								<Button type="submit" disabled={endItemMaintenance.pending > 0}>
									{endItemMaintenance.pending > 0
										? "Ending maintenance…"
										: "End maintenance"}
								</Button>
							</form>
						{:else}
							<form
								{...startItemMaintenance.enhance(async (form) => {
									if (await form.submit())
										handleItemCommand(form.result, "Maintenance started");
								})}
								class="space-y-4"
								aria-busy={startItemMaintenance.pending > 0}
							>
								<input
									type="hidden"
									name={startItemMaintenance.fields.slugOrId.as(
										"hidden",
										selected.slug,
									).name}
									value={selected.slug}
								/>
								{#each startItemMaintenance.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{issue.message}
									</p>{/each}
								{#if startItemMaintenance.result && !startItemMaintenance.result.ok}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{startItemMaintenance.result.error}
									</p>{/if}
								<div>
									<Label for="maintenance-reason" class="mb-2.5"
										>Maintenance reason <span
											class="font-normal text-muted-foreground">(required)</span
										></Label
									>
									<Textarea
										id="maintenance-reason"
										name={startItemMaintenance.fields.reason.as("text").name}
										bind:value={maintenanceReason}
									/>
								</div>
								<Button
									type="submit"
									disabled={!maintenanceReason.trim() ||
										startItemMaintenance.pending > 0}
								>
									{startItemMaintenance.pending > 0
										? "Starting maintenance…"
										: "Start maintenance"}
								</Button>
							</form>
						{/if}

						<div class="space-y-3 border-t pt-5">
							<h4 class="font-semibold">Maintenance history</h4>
							{#each maintenanceQuery.data ?? [] as period (period.id)}
								<div class="rounded-xl bg-muted/45 p-3 text-sm">
									<div class="font-medium">{period.startReason}</div>
									<div class="mt-1 text-muted-foreground">
										{new Date(period.startedAt).toLocaleString()} · {period.open
											? "Open"
											: "Ended"}
									</div>
									{#if period.endNote}<div class="mt-2">
											{period.endNote}
										</div>{/if}
								</div>
							{:else}
								<p class="text-sm text-muted-foreground">
									No maintenance history.
								</p>
							{/each}
						</div>
					</section>
				</Tabs.Content>
			</Tabs.Root>
		</div>
	</section>

	<AlertDialog.Root bind:open={deleteConfirmOpen}>
		<AlertDialog.Content>
			<AlertDialog.Header>
				<AlertDialog.Title>Delete {selected.label}?</AlertDialog.Title>
				<AlertDialog.Description>
					This permanently removes the item. Items with retained history must be
					archived instead.
				</AlertDialog.Description>
			</AlertDialog.Header>
			<AlertDialog.Footer>
				<AlertDialog.Cancel>Cancel</AlertDialog.Cancel>
				<AlertDialog.Action
					class={buttonVariants({ variant: "destructive" })}
					disabled={deleteItem.isPending}
					onclick={() =>
						deleteItem.mutate({
							path: { slugOrId: selected!.slug },
							body: { confirm: true },
						})}
				>
					Delete permanently
				</AlertDialog.Action>
			</AlertDialog.Footer>
		</AlertDialog.Content>
	</AlertDialog.Root>
{/if}
