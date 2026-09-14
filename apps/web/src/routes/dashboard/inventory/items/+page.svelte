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
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import { Textarea } from "$lib/components/ui/textarea";
import { apiErrorMessage } from "$lib/api-error";
import {
	Archive,
	PackagePlus,
	RefreshCw,
	RotateCcw,
	Trash2,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";

let archived = $state<"exclude" | "include" | "only">("exclude");
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
function choose(item: InventoryOperatorItem) {
	selected = item;
	editNotes = item.notes ?? "";
	editValues = itemValues(item);
	moveContainerId = item.containerId ?? "";
	newCategoryId = item.categoryId;
	newCategoryValues = itemValues(item);
	maintenanceReason = "";
	maintenanceEndNote = "";
	archiveReason = "";
}
function resetCreate() {
	notes = "";
	values = {};
}
function commandOptions(success: string, fallback: string, after?: () => void) {
	return {
		onSuccess: (response: { data: InventoryOperatorItem }) => {
			toast.success(success);
			if (selected) choose(response.data);
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
			<Label for={`${prefix}-${definition.id}`}>{definition.label}</Label>
			{#if definition.valueType === "boolean"}
				<select
					id={`${prefix}-${definition.id}`}
					class="h-10 w-full rounded-md border bg-background px-3"
					value={target[definition.id] === true
						? "true"
						: target[definition.id] === false
							? "false"
							: ""}
					onchange={(event) =>
						setValue(
							target,
							definition.id,
							event.currentTarget.value === ""
								? ""
								: event.currentTarget.value === "true",
						)}
					required={definition.required}
				>
					<option value="">Not set</option><option value="true">Yes</option
					><option value="false">No</option>
				</select>
			{:else if definition.valueType === "single_select"}
				<select
					id={`${prefix}-${definition.id}`}
					class="h-10 w-full rounded-md border bg-background px-3"
					value={String(target[definition.id] ?? "")}
					onchange={(event) =>
						setValue(target, definition.id, event.currentTarget.value)}
					required={definition.required}
				>
					<option value="">Choose</option
					>{#each definition.options.filter((option) => !option.retiredAt) as option (option.id)}<option
							value={option.id}>{option.label}</option
						>{/each}
				</select>
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
<div class="mx-auto max-w-7xl space-y-6 px-4 py-8 sm:px-6">
	<header>
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Operator inventory
		</p>
		<h1 class="font-heading text-3xl font-bold">Items</h1>
		<p class="mt-2 text-sm text-muted-foreground">
			Track each physical unit by its immutable slug, derived label, storage,
			and retained maintenance periods.
		</p>
	</header>
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
	<div class="grid gap-6 xl:grid-cols-[22rem_1fr]">
		<form
			class="space-y-4 rounded-2xl border bg-card p-5"
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
			<h2 class="text-lg font-semibold">Add physical item</h2>
			<div>
				<Label for="item-category">Category</Label><select
					id="item-category"
					class="h-10 w-full rounded-md border bg-background px-3"
					bind:value={categoryId}
					onchange={() => (values = {})}
					required
					><option value="">Choose category</option
					>{#each categoriesQuery.data ?? [] as category (category.id)}<option
							value={category.id}>{category.name}</option
						>{/each}</select
				>
			</div>
			<div>
				<Label for="item-container">Container</Label><select
					id="item-container"
					class="h-10 w-full rounded-md border bg-background px-3"
					bind:value={containerId}
					required
					><option value="">Choose container</option
					>{#each (containersQuery.data ?? []).filter((container) => !container.archivedAt) as container (container.id)}<option
							value={container.id}>{container.name}</option
						>{/each}</select
				>
			</div>
			{@render fields(definitionsQuery.data ?? [], values, "create")}
			<div>
				<Label for="item-notes">Notes</Label><Textarea
					id="item-notes"
					bind:value={notes}
				/>
			</div>
			<Button type="submit" disabled={createItem.isPending}
				><PackagePlus />Add item</Button
			>
		</form>
		<section class="space-y-3">
			<div class="flex flex-wrap items-end justify-between gap-3">
				<div>
					<h2 class="text-lg font-semibold">Item register</h2>
					<p class="text-sm text-muted-foreground">
						{itemsQuery.data?.totalCount ?? 0} physical units
					</p>
				</div>
				<div class="flex flex-1 flex-wrap justify-end gap-3">
					<div class="min-w-56 flex-1 sm:max-w-80">
						<Label for="item-search">Search</Label>
						<Input
							id="item-search"
							type="search"
							placeholder="Slug, label, container or notes"
							value={search}
							oninput={(event) => updateSearch(event.currentTarget.value)}
						/>
					</div>
					<div>
						<Label for="archive-filter">Archive filter</Label><select
							id="archive-filter"
							class="h-10 rounded-md border bg-background px-3"
							bind:value={archived}
							><option value="exclude">Active</option><option value="include"
								>All</option
							><option value="only">Archived</option></select
						>
					</div>
				</div>
			</div>
			{#each itemsQuery.data?.items ?? [] as item (item.id)}<article
					class="rounded-2xl border bg-card p-4 shadow-sm {item.archivedAt
						? 'opacity-65'
						: ''}"
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
								{item.category?.name} · {item.container?.name ?? "No container"}
							</p>
							{#if item.values.length}<p class="mt-1 text-sm">
									{displayValue(item)}
								</p>{/if}{#if item.notes}<p class="mt-1 text-sm">
									{item.notes}
								</p>{/if}
						</div>
						<Button size="sm" variant="outline" onclick={() => choose(item)}
							>Manage</Button
						>
					</div>
				</article>{:else}<div
					class="rounded-2xl border bg-card p-10 text-center"
				>
					<h2 class="font-semibold">No items found</h2>
					<p class="text-sm text-muted-foreground">
						{debouncedQuery
							? "Try another search or change the filters."
							: "Create a physical unit or change the archive filter."}
					</p>
				</div>{/each}
		</section>
	</div>
	{#if selected}<section class="space-y-5 rounded-2xl border bg-card p-5">
			<div class="flex flex-wrap items-start justify-between gap-3">
				<div>
					<div class="flex flex-wrap items-center gap-2">
						<h2 class="font-heading text-2xl font-bold">{selected.label}</h2>
						{#if selected.archivedAt}<Badge variant="outline">Archived</Badge
							>{/if}
					</div>
					<p class="font-mono text-sm text-muted-foreground">{selected.slug}</p>
				</div>
				<Button variant="outline" onclick={() => (selected = undefined)}
					>Close</Button
				>
			</div>
			<div class="grid gap-5 lg:grid-cols-2 xl:grid-cols-3">
				<form
					class="space-y-3 rounded-xl border p-4"
					onsubmit={(event) => {
						event.preventDefault();
						updateItem.mutate({
							path: { slugOrId: selected!.slug },
							body: { notes: editNotes.trim() || null, values: editValues },
						});
					}}
				>
					<h3 class="font-semibold">Edit current facts</h3>
					{@render fields(editDefinitionsQuery.data ?? [], editValues, "edit")}
					<div>
						<Label for="edit-notes">Notes</Label><Textarea
							id="edit-notes"
							bind:value={editNotes}
						/>
					</div>
					<Button type="submit">Save item</Button>
				</form>
				<div class="space-y-5">
					<form
						class="space-y-3 rounded-xl border p-4"
						onsubmit={(event) => {
							event.preventDefault();
							moveItem.mutate({
								path: { slugOrId: selected!.slug },
								body: { containerId: moveContainerId },
							});
						}}
					>
						<h3 class="font-semibold">Move</h3>
						<div>
							<Label for="move-container">Move to container</Label><select
								id="move-container"
								class="h-10 w-full rounded-md border bg-background px-3"
								bind:value={moveContainerId}
								required
								>{#each (containersQuery.data ?? []).filter((container) => !container.archivedAt) as container (container.id)}<option
										value={container.id}>{container.name}</option
									>{/each}</select
							>
						</div>
						<Button type="submit">Move item</Button>
					</form>
					<form
						class="space-y-3 rounded-xl border p-4"
						onsubmit={(event) => {
							event.preventDefault();
							changeCategory.mutate({
								path: { slugOrId: selected!.slug },
								body: { categoryId: newCategoryId, values: newCategoryValues },
							});
						}}
					>
						<h3 class="font-semibold">Reclassify</h3>
						<div>
							<Label for="new-category">New category</Label><select
								id="new-category"
								class="h-10 w-full rounded-md border bg-background px-3"
								bind:value={newCategoryId}
								onchange={() => (newCategoryValues = {})}
								required
								>{#each categoriesQuery.data ?? [] as category (category.id)}<option
										value={category.id}>{category.name}</option
									>{/each}</select
							>
						</div>
						{@render fields(
							newDefinitionsQuery.data ?? [],
							newCategoryValues,
							"category",
						)}<Button type="submit">Change category</Button>
					</form>
				</div>
				<div class="space-y-5">
					<div class="space-y-3 rounded-xl border p-4">
						<h3 class="font-semibold">Maintenance</h3>
						{#if selected.availability.status === "maintenance"}<Label
								for="maintenance-end-note">Maintenance end note</Label
							><Textarea
								id="maintenance-end-note"
								bind:value={maintenanceEndNote}
							/><Button
								onclick={() =>
									endMaintenance.mutate({
										path: { slugOrId: selected!.slug },
										body: { endNote: maintenanceEndNote.trim() || null },
									})}>End maintenance</Button
							>{:else}<Label for="maintenance-reason">Maintenance reason</Label
							><Textarea
								id="maintenance-reason"
								bind:value={maintenanceReason}
							/><Button
								disabled={!maintenanceReason.trim()}
								onclick={() =>
									startMaintenance.mutate({
										path: { slugOrId: selected!.slug },
										body: { reason: maintenanceReason.trim() },
									})}>Start maintenance</Button
							>{/if}
						<div class="space-y-2 border-t pt-3">
							{#each maintenanceQuery.data ?? [] as period (period.id)}<div
									class="text-sm"
								>
									<div class="font-medium">{period.startReason}</div>
									<div class="text-muted-foreground">
										{new Date(period.startedAt).toLocaleString()} · {period.open
											? "Open"
											: "Ended"}
									</div>
									{#if period.endNote}<div>{period.endNote}</div>{/if}
								</div>{:else}<p class="text-sm text-muted-foreground">
									No maintenance history.
								</p>{/each}
						</div>
					</div>
					<div class="space-y-3 rounded-xl border p-4">
						<h3 class="font-semibold">Lifecycle</h3>
						{#if selected.archivedAt}<Button
								variant="outline"
								onclick={() =>
									restoreItem.mutate({ path: { slugOrId: selected!.slug } })}
								><RotateCcw />Restore item</Button
							>{:else}<Label for="archive-reason">Archive note</Label><Input
								id="archive-reason"
								bind:value={archiveReason}
							/>
							<div class="flex flex-wrap gap-2">
								<Button
									variant="outline"
									onclick={() =>
										archiveItem.mutate({
											path: { slugOrId: selected!.slug },
											body: { reason: archiveReason.trim() || null },
										})}><Archive />Archive item</Button
								><Button
									variant="destructive"
									onclick={() =>
										deleteItem.mutate({
											path: { slugOrId: selected!.slug },
											body: { confirm: true },
										})}><Trash2 />Delete item</Button
								>
							</div>{/if}
					</div>
				</div>
			</div>
		</section>{/if}
</div>
