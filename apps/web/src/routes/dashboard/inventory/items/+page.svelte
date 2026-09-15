<script lang="ts">
import { onDestroy } from "svelte";
import { createMutation, createQuery } from "@tanstack/svelte-query";
import {
	type InventoryOperatorItem,
	type InventoryOperatorItemValues,
	type InventoryPropertyDefinition,
	inventoryCategoriesIndexOptions,
	inventoryContainersIndexOptions,
	inventoryItemsArchiveMutation,
	inventoryItemsChangeCategoryMutation,
	inventoryItemsCreateMutation,
	inventoryItemsDeleteMutation,
	inventoryItemsEndMaintenanceMutation,
	inventoryItemsListMaintenanceOptions,
	inventoryItemsListOptions,
	inventoryItemsMoveMutation,
	inventoryItemsRestoreMutation,
	inventoryItemsStartMaintenanceMutation,
	inventoryItemsUpdateMutation,
	inventoryStructureListDefinitionsOptions,
} from "@dhc/api-client";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import * as AlertDialog from "$lib/components/ui/alert-dialog";
import * as Accordion from "$lib/components/ui/accordion";
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
	MapPin,
	NotebookPen,
	PackageSearch,
	PackagePlus,
	RefreshCw,
	RotateCcw,
	Tags,
	Trash2,
	Wrench,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";

let archived = $state<"exclude" | "include" | "only">("exclude");
let availability = $state<"all" | "maintenance">("all");
let search = $state("");
let debouncedQuery = $state("");
let searchTimeout: ReturnType<typeof setTimeout> | undefined;
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
let createOpen = $state(false);
let createTrigger = $state<HTMLButtonElement | null>(null);
type ManagementTab = "details" | "placement" | "maintenance";
let managementTab = $state<ManagementTab>("details");
let managementTrigger = $state<HTMLElement | null>(null);
let deleteConfirmOpen = $state(false);

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
		query: { archived, limit: 100, q: debouncedQuery || undefined },
	}),
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

function refresh() {
	void itemsQuery.refetch();
	void maintenanceQuery.refetch();
}
function updateSearch(value: string) {
	search = value;
	clearTimeout(searchTimeout);
	searchTimeout = setTimeout(() => {
		debouncedQuery = value.trim();
	}, 300);
}
onDestroy(() => clearTimeout(searchTimeout));
function itemValues(item: InventoryOperatorItem): InventoryOperatorItemValues {
	return Object.fromEntries(
		item.values.map((value) => [
			value.definitionId,
			value.text ?? value.decimal ?? value.boolean ?? value.optionId,
		]),
	);
}
function choose(item: InventoryOperatorItem, tab: ManagementTab = "details") {
	selected = item;
	managementTab = tab;
	editNotes = item.notes ?? "";
	editValues = itemValues(item);
	moveContainerId = item.containerId ?? "";
	newCategoryId = item.categoryId;
	newCategoryValues = itemValues(item);
	maintenanceReason = "";
	maintenanceEndNote = "";
	archiveReason = "";
	deleteConfirmOpen = false;
}
function openManagement(
	item: InventoryOperatorItem,
	tab: ManagementTab,
	trigger: HTMLElement,
) {
	managementTrigger = trigger;
	choose(item, tab);
}
function resetCreate() {
	notes = "";
	values = {};
	createOpen = false;
}
function commandOptions(success: string, fallback: string, after?: () => void) {
	return {
		onSuccess: (response: { data: InventoryOperatorItem }) => {
			toast.success(success);
			if (selected) choose(response.data, managementTab);
			after?.();
			refresh();
		},
		onError: apiErrorHandler(fallback),
	};
}
function apiErrorHandler(fallback: string) {
	return (cause: unknown) => toast.error(apiErrorMessage(cause, fallback));
}
const createItem = createMutation(() => ({
	...inventoryItemsCreateMutation(),
	...commandOptions("Item created", "Could not create item", resetCreate),
}));
const updateItem = createMutation(() => ({
	...inventoryItemsUpdateMutation(),
	...commandOptions("Item updated", "Could not update item"),
}));
const moveItem = createMutation(() => ({
	...inventoryItemsMoveMutation(),
	...commandOptions("Item moved", "Could not move item"),
}));
const changeCategory = createMutation(() => ({
	...inventoryItemsChangeCategoryMutation(),
	...commandOptions("Category changed", "Could not change category"),
}));
const startMaintenance = createMutation(() => ({
	...inventoryItemsStartMaintenanceMutation(),
	...commandOptions("Maintenance started", "Could not start maintenance"),
}));
const endMaintenance = createMutation(() => ({
	...inventoryItemsEndMaintenanceMutation(),
	...commandOptions("Maintenance ended", "Could not end maintenance"),
}));
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
	},
	onError: (error) =>
		toast.error(apiErrorMessage(error, "Items with history must be archived")),
}));

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
				{definition.label}
			</Label>
			{#if definition.valueType === "boolean"}
				<Select.Root
					type="single"
					name={`${prefix}-${definition.id}`}
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
					name={`${prefix}-${definition.id}`}
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

<svelte:head><title>Inventory items | Dublin HEMA Club</title></svelte:head>

{#snippet createAction()}
	<Button bind:ref={createTrigger} onclick={() => (createOpen = true)}>
		<PackagePlus aria-hidden="true" />New item
	</Button>
{/snippet}

<Sheet.Root
	bind:open={createOpen}
	onOpenChangeComplete={(open) => {
		if (!open) createTrigger?.focus();
	}}
>
	<div
		class="inventory-page xl:flex xl:h-[calc(100svh-2.8125rem)] xl:flex-col xl:space-y-4 xl:overflow-hidden xl:py-4"
	>
		<InventoryPageHeader
			eyebrow="Operator inventory"
			title="Items"
			icon={PackageSearch}
			actions={createAction}
			class="xl:pb-3"
		/>
		{#if itemsQuery.data && maintenanceItems.length > 0}
			<section
				class="rounded-2xl border border-secondary/60 bg-secondary/10 px-4 shadow-sm sm:px-5"
			>
				<Accordion.Root type="single">
					<Accordion.Item value="maintenance" class="border-0">
						<Accordion.Trigger
							level={2}
							class="items-center py-4 hover:no-underline sm:py-5"
						>
							<div class="flex min-w-0 items-start gap-3">
								<div
									class="grid size-11 shrink-0 place-items-center rounded-xl bg-secondary/25 text-foreground"
								>
									<Wrench class="size-5" aria-hidden="true" />
								</div>
								<div class="min-w-0 flex-1">
									<div class="flex flex-wrap items-center gap-2">
										<span class="font-heading text-xl font-bold">
											Maintenance attention
										</span>
										<Badge variant="secondary"
											>{maintenanceItems.length} open</Badge
										>
									</div>
									<span
										class="mt-1 block text-sm font-normal text-muted-foreground"
									>
										These items are out of circulation and need an operator
										decision.
									</span>
								</div>
							</div>
						</Accordion.Trigger>
						<Accordion.Content>
							<div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
								{#each maintenanceItems.slice(0, 3) as item (item.id)}
									<article class="rounded-xl border bg-background/90 p-3">
										<div class="flex items-start justify-between gap-3">
											<div class="min-w-0">
												<h3 class="font-semibold leading-snug">{item.label}</h3>
												<p class="mt-1 font-mono text-xs text-muted-foreground">
													{item.slug}
												</p>
											</div>
											<Button
												size="sm"
												onclick={(event) =>
													openManagement(
														item,
														"maintenance",
														event.currentTarget,
													)}
											>
												Manage maintenance
											</Button>
										</div>
									</article>
								{/each}
							</div>
							<div
								class="mt-4 flex justify-end border-t border-secondary/40 pt-4"
							>
								<Button
									variant="outline"
									onclick={() => (availability = "maintenance")}
								>
									View all {maintenanceItems.length} maintenance {maintenanceItems.length ===
									1
										? "item"
										: "items"}
								</Button>
							</div>
						</Accordion.Content>
					</Accordion.Item>
				</Accordion.Root>
			</section>
		{/if}
		{#if itemsQuery.isError}<Alert variant="destructive"
				><AlertDescription class="flex items-center justify-between"
					><span
						>{apiErrorMessage(itemsQuery.error, "Could not load items")}</span
					><Button
						variant="outline"
						size="sm"
						onclick={() => itemsQuery.refetch()}><RefreshCw />Try again</Button
					></AlertDescription
				></Alert
			>{/if}
		<div class="min-h-0 xl:flex-1">
			<Sheet.Content
				side="right"
				class="w-full max-w-none gap-0 overflow-hidden p-0 sm:w-[50rem] sm:max-w-[calc(100vw-2rem)]"
			>
				<form
					class="flex min-h-0 flex-1 flex-col"
					onsubmit={(event) => {
						event.preventDefault();
						createItem.mutate({
							body: {
								categoryId,
								containerId,
								notes: notes.trim() || null,
								values,
							},
						});
					}}
				>
					<Sheet.Header
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
									New inventory unit
								</p>
								<Sheet.Title class="font-heading text-2xl font-bold">
									Add physical item
								</Sheet.Title>
								<Sheet.Description class="mt-1 text-sm leading-relaxed">
									The label and permanent item code are generated for you.
								</Sheet.Description>
							</div>
						</div>
					</Sheet.Header>

					<div
						class="min-h-0 flex-1 space-y-6 overflow-y-auto overscroll-contain bg-muted/20 p-5 sm:p-8"
					>
						<fieldset
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm sm:p-6"
						>
							<legend class="sr-only">Classify and place</legend>
							<div class="flex items-start gap-3 border-b pb-4">
								<span
									class="grid size-8 shrink-0 place-items-center rounded-full bg-secondary text-sm font-bold text-secondary-foreground"
									>1</span
								>
								<div>
									<h3 class="font-heading text-lg font-bold">
										Classify and place
									</h3>
									<p class="mt-0.5 text-sm text-muted-foreground">
										Choose what the item is and where operators can find it.
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
									<Select.Root
										type="single"
										name="categoryId"
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
									<Select.Root
										type="single"
										name="containerId"
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
							<legend class="sr-only">Describe the unit</legend>
							<div class="flex items-start gap-3 border-b pb-4">
								<span
									class="grid size-8 shrink-0 place-items-center rounded-full bg-secondary text-sm font-bold text-secondary-foreground"
									>2</span
								>
								<div>
									<h3 class="font-heading text-lg font-bold">
										Describe the unit
									</h3>
									<p class="mt-0.5 text-sm text-muted-foreground">
										Record identifying properties and useful operator notes.
									</p>
								</div>
							</div>
							{#if categoryId}
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
								><Textarea id="item-notes" bind:value={notes} />
								<p class="mt-1.5 text-xs text-muted-foreground">
									Optional condition or identification details for operators.
								</p>
							</div>
						</fieldset>
					</div>

					<Sheet.Footer
						class="shrink-0 border-t bg-background p-4 sm:flex-row sm:justify-between sm:px-6"
					>
						<Sheet.Close class={buttonVariants({ variant: "outline" })}>
							Cancel
						</Sheet.Close>
						<Button
							type="submit"
							class="min-h-11 sm:min-w-36"
							disabled={createItem.isPending}><PackagePlus />Add item</Button
						>
					</Sheet.Footer>
				</form>
			</Sheet.Content>
			<section class="min-h-0 space-y-3 xl:flex xl:h-full xl:flex-col">
				<div
					class="inventory-panel flex flex-wrap items-end justify-between gap-4 p-4"
				>
					<div>
						<h2 class="text-lg font-semibold">Item register</h2>
						<p class="text-sm text-muted-foreground">
							{itemsQuery.data?.totalCount ?? 0} physical units
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
								placeholder="Slug, label, container or notes"
								value={search}
								oninput={(event) => updateSearch(event.currentTarget.value)}
							/>
						</div>
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
									onclick={(event) =>
										openManagement(item, "details", event.currentTarget)}
									>Manage</Button
								>
							</div>
						</article>{:else}<div
							class="rounded-2xl border bg-card p-10 text-center"
						>
							<h2 class="font-semibold">The register is empty</h2>
							<p class="text-sm text-muted-foreground">
								{debouncedQuery
									? "Try another search or change the filters."
									: "Create a physical unit or change the archive filter."}
							</p>
						</div>{/each}
				</div>
			</section>
		</div>
	</div>
</Sheet.Root>

{#if selected}
	<Sheet.Root
		open
		onOpenChange={(open) => {
			if (!open) selected = undefined;
		}}
		onOpenChangeComplete={(open) => {
			if (!open) managementTrigger?.focus();
		}}
	>
		<Sheet.Content
			side="right"
			class="w-full max-w-none gap-0 overflow-hidden p-0 sm:w-[46rem] sm:max-w-[calc(100vw-2rem)]"
		>
			<Sheet.Header
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
							<Sheet.Title class="font-heading text-2xl font-bold">
								{selected.label}
							</Sheet.Title>
							{#if selected.archivedAt}<Badge variant="outline">Archived</Badge
								>{/if}
						</div>
						<Sheet.Description class="mt-1 font-mono text-sm">
							{selected.slug}
						</Sheet.Description>
					</div>
				</div>
			</Sheet.Header>

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
						class="flex h-full min-h-0 flex-col"
						onsubmit={(event) => {
							event.preventDefault();
							updateItem.mutate({
								path: { slugOrId: selected!.slug },
								body: { notes: editNotes.trim() || null, values: editValues },
							});
						}}
					>
						<div
							class="min-h-0 flex-1 space-y-6 overflow-y-auto bg-muted/20 p-5 sm:p-6"
						>
							<section
								class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
							>
								<div class="border-b pb-4">
									<h3 class="font-heading text-lg font-bold">Current facts</h3>
									<p class="mt-1 text-sm text-muted-foreground">
										Update identifying properties and operator notes.
									</p>
								</div>
								{@render fields(
									editDefinitionsQuery.data ?? [],
									editValues,
									"edit",
								)}
								<div>
									<Label for="edit-notes" class="mb-2.5">Notes</Label>
									<Textarea id="edit-notes" bind:value={editNotes} />
								</div>
							</section>

							<section
								class="space-y-4 rounded-2xl border bg-card p-5 shadow-sm"
							>
								<div>
									<h3 class="font-heading text-lg font-bold">Lifecycle</h3>
									<p class="mt-1 text-sm text-muted-foreground">
										Archive items you need to retain. Delete only unused
										records.
									</p>
								</div>
								{#if selected.archivedAt}
									<Button
										type="button"
										variant="outline"
										onclick={() =>
											restoreItem.mutate({
												path: { slugOrId: selected!.slug },
											})}
									>
										<RotateCcw />Restore item
									</Button>
								{:else}
									<div>
										<Label for="archive-reason" class="mb-2.5"
											>Archive note</Label
										>
										<Input id="archive-reason" bind:value={archiveReason} />
									</div>
									<div class="flex flex-wrap gap-2 border-t pt-4">
										<Button
											type="button"
											variant="outline"
											onclick={() =>
												archiveItem.mutate({
													path: { slugOrId: selected!.slug },
													body: { reason: archiveReason.trim() || null },
												})}
										>
											<Archive />Archive item
										</Button>
										<Button
											type="button"
											variant="destructive"
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
								disabled={updateItem.isPending}
							>
								Save item
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
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
							onsubmit={(event) => {
								event.preventDefault();
								moveItem.mutate({
									path: { slugOrId: selected!.slug },
									body: { containerId: moveContainerId },
								});
							}}
						>
							<div class="border-b pb-4">
								<h3 class="font-heading text-lg font-bold">Move item</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Change where operators can find this physical unit.
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
							</div>
							<Button type="submit" disabled={moveItem.isPending}
								>Move item</Button
							>
						</form>

						<form
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
							onsubmit={(event) => {
								event.preventDefault();
								changeCategory.mutate({
									path: { slugOrId: selected!.slug },
									body: {
										categoryId: newCategoryId,
										values: newCategoryValues,
									},
								});
							}}
						>
							<div class="border-b pb-4">
								<h3 class="font-heading text-lg font-bold">Change category</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Reclassifying replaces the category-specific facts below.
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
							{@render fields(
								newDefinitionsQuery.data ?? [],
								newCategoryValues,
								"category",
							)}
							<Button type="submit" disabled={changeCategory.isPending}
								>Change category</Button
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
							<div>
								<Label for="maintenance-end-note" class="mb-2.5"
									>Maintenance end note</Label
								>
								<Textarea
									id="maintenance-end-note"
									bind:value={maintenanceEndNote}
								/>
							</div>
							<Button
								disabled={endMaintenance.isPending}
								onclick={() =>
									endMaintenance.mutate({
										path: { slugOrId: selected!.slug },
										body: { endNote: maintenanceEndNote.trim() || null },
									})}
							>
								End maintenance
							</Button>
						{:else}
							<div>
								<Label for="maintenance-reason" class="mb-2.5"
									>Maintenance reason</Label
								>
								<Textarea
									id="maintenance-reason"
									bind:value={maintenanceReason}
								/>
							</div>
							<Button
								disabled={!maintenanceReason.trim() ||
									startMaintenance.isPending}
								onclick={() =>
									startMaintenance.mutate({
										path: { slugOrId: selected!.slug },
										body: { reason: maintenanceReason.trim() },
									})}
							>
								Start maintenance
							</Button>
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
		</Sheet.Content>
	</Sheet.Root>

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
