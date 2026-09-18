<script lang="ts">
import { pushState, replaceState } from "$app/navigation";
import { page } from "$app/state";
import { createQuery, keepPreviousData } from "@tanstack/svelte-query";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
} from "$lib/components/ui/select";
import { Skeleton } from "$lib/components/ui/skeleton";
import * as Sheet from "$lib/components/ui/sheet";
import InventoryPageHeader from "$lib/components/inventory/InventoryPageHeader.svelte";
import MemberEquipmentItem from "$lib/components/inventory/MemberEquipmentItem.svelte";
import CatalogPropertyFilters from "$lib/components/inventory/CatalogPropertyFilters.svelte";
import {
	encodePropertyFilter,
	propertyFilterEntries,
} from "$lib/inventory/property-filter";
import {
	isModifiedClick,
	sheetSelection,
} from "$lib/inventory/sheet-selection";
import {
	ArrowRight,
	Package,
	Search,
	RefreshCw,
	SlidersHorizontal,
} from "@lucide/svelte";
import {
	inventoryCatalogListItemsOptions,
	inventoryCategoriesIndexOptions,
	inventoryStructureListDefinitionsOptions,
} from "@dhc/api-client";

// ALE-288 member browse (ALE-280 story 58): the browse half of the
// browse-decide-request-collect journey. Reads the member catalog only —
// label, slug, category, values, and the generic availability reason — so
// no container, note, or maintenance fact can reach this view.

type AvailabilityFilter = "all" | "available" | "unavailable";

const LIST_PATH = "/dashboard/equipment";
const PAGE_SIZE = 25;
const ALL_CATEGORIES = "all-categories";
const availabilityOptions: Array<{
	value: AvailabilityFilter;
	label: string;
}> = [
	{ value: "all", label: "Everything" },
	{ value: "available", label: "Available now" },
	{ value: "unavailable", label: "Unavailable" },
];

let searchInput = $state("");
let appliedSearch = $state<string | undefined>(undefined);
let categoryInput = $state(ALL_CATEGORIES);
let availability = $state<AvailabilityFilter>("all");
let propertyValues = $state<Record<string, string>>({});
let cursor = $state<string | undefined>(undefined);
let selectedItemTrigger = $state<HTMLElement | null>(null);

const selectedItemSlug = $derived(
	sheetSelection(page.url.pathname, LIST_PATH, page.state.selectedSlug),
);

const categoriesQuery = createQuery(() => ({
	...inventoryCategoriesIndexOptions(),
	select: (response) => response.data.categories,
}));

const definitionsQuery = createQuery(() => ({
	...inventoryStructureListDefinitionsOptions({
		path: { categoryId: categoryInput },
	}),
	enabled: categoryInput !== ALL_CATEGORIES,
	select: (response) => response.data.definitions,
}));

const propertyFilter = $derived(
	encodePropertyFilter(propertyFilterEntries(propertyValues)),
);

const catalogQuery = createQuery(() => ({
	...inventoryCatalogListItemsOptions({
		query: {
			limit: PAGE_SIZE,
			q: appliedSearch,
			categoryId: categoryInput === ALL_CATEGORIES ? undefined : categoryInput,
			availability,
			property: propertyFilter,
			cursor,
		},
	}),
	placeholderData: keepPreviousData,
	select: (response) => response.data,
}));

const items = $derived(catalogQuery.data?.items ?? []);
const categoryOptions = $derived([
	{ value: ALL_CATEGORIES, label: "All categories" },
	...(categoriesQuery.data ?? []).map((category) => ({
		value: category.id,
		label: category.name,
	})),
]);
const hasActiveFilters = $derived(
	appliedSearch ||
		categoryInput !== ALL_CATEGORIES ||
		availability !== "all" ||
		Boolean(propertyFilter),
);
const selectedCategoryLabel = $derived(
	categoryOptions.find((option) => option.value === categoryInput)?.label ??
		"Category",
);

function applySearch() {
	const trimmed = searchInput.trim();
	appliedSearch = trimmed ? trimmed : undefined;
	cursor = undefined;
}

function onFilterChange() {
	cursor = undefined;
}

function onCategoryChange() {
	propertyValues = {};
	cursor = undefined;
}

function clearFilters() {
	searchInput = "";
	appliedSearch = undefined;
	categoryInput = ALL_CATEGORIES;
	availability = "all";
	propertyValues = {};
	cursor = undefined;
}

function openItem(slug: string, trigger: HTMLElement) {
	selectedItemTrigger = trigger;
	pushState(`${LIST_PATH}/${slug}`, { selectedSlug: slug });
}

function closeSheet() {
	if (page.state.selectedSlug) {
		history.back();
		return;
	}
	if (selectedItemSlug) {
		replaceState(LIST_PATH, {});
	}
}

function availabilityLabel(reason: string): string {
	switch (reason) {
		case "available":
			return "Available";
		case "on_loan":
			return "On loan";
		case "maintenance":
			return "Maintenance";
		default:
			return reason;
	}
}
</script>

<svelte:head>
	<title>Browse equipment | Dublin HEMA Club</title>
</svelte:head>

<div class="inventory-page max-w-6xl">
	<InventoryPageHeader
		eyebrow="Member inventory"
		title="Find the right kit"
		icon={Package}
	/>

	<section class="inventory-panel p-3 sm:p-4" aria-label="Equipment filters">
		<form
			class="relative"
			onsubmit={(e) => {
				e.preventDefault();
				applySearch();
			}}
		>
			<Label for="equipment-search" class="sr-only">Search items</Label>
			<Search
				class="pointer-events-none absolute left-4 top-1/2 size-5 -translate-y-1/2 text-muted-foreground"
				aria-hidden="true"
			/>
			<Input
				id="equipment-search"
				class="h-12 border-0 bg-muted/60 pl-11 text-base shadow-none focus-visible:bg-background"
				placeholder="Search swords, masks, size…"
				bind:value={searchInput}
			/>
		</form>

		<div
			class="mt-3 grid grid-cols-2 gap-3 border-t pt-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
		>
			<div class="min-w-0 space-y-1.5">
				<Label class="text-xs font-medium">Category</Label>
				<Select
					type="single"
					items={categoryOptions}
					bind:value={categoryInput}
					onValueChange={onCategoryChange}
				>
					<SelectTrigger class="min-h-11 w-full">
						{selectedCategoryLabel}
					</SelectTrigger>
					<SelectContent>
						{#each categoryOptions as option (option.value)}
							<SelectItem value={option.value} label={option.label}
								>{option.label}</SelectItem
							>
						{/each}
					</SelectContent>
				</Select>
			</div>
			<div class="min-w-0 space-y-1.5">
				<Label class="text-xs font-medium">Availability</Label>
				<Select
					type="single"
					items={availabilityOptions}
					bind:value={availability}
					onValueChange={onFilterChange}
				>
					<SelectTrigger class="min-h-11 w-full">
						{availabilityOptions.find((option) => option.value === availability)
							?.label}
					</SelectTrigger>
					<SelectContent>
						{#each availabilityOptions as option (option.value)}
							<SelectItem value={option.value} label={option.label}
								>{option.label}</SelectItem
							>
						{/each}
					</SelectContent>
				</Select>
			</div>
			<Button
				variant="outline"
				class="col-span-2 min-h-11 sm:col-span-1"
				disabled={!hasActiveFilters}
				onclick={clearFilters}
			>
				<SlidersHorizontal class="size-4" aria-hidden="true" />
				Clear filters
			</Button>
		</div>

		{#if categoryInput !== ALL_CATEGORIES}
			<CatalogPropertyFilters
				definitions={definitionsQuery.data ?? []}
				bind:values={propertyValues}
				onChange={onFilterChange}
			/>
		{/if}
	</section>

	{#if catalogQuery.isPending}
		<div class="space-y-3" aria-label="Loading equipment">
			{#each { length: 3 } as _, index (index)}
				<div class="rounded-2xl border border-border bg-card p-4">
					<div class="flex gap-3">
						<Skeleton class="size-12 shrink-0 rounded-xl" />
						<div class="flex-1 space-y-2">
							<Skeleton class="h-5 w-2/3" />
							<Skeleton class="h-4 w-1/2" />
						</div>
					</div>
				</div>
			{/each}
		</div>
	{:else if catalogQuery.isError}
		<Alert variant="destructive">
			<AlertDescription
				class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
			>
				<span>
					{catalogQuery.error.errors?.detail ??
						"We couldn't load the equipment catalog."}
				</span>
				<Button
					variant="outline"
					size="sm"
					class="min-h-10"
					onclick={() => catalogQuery.refetch()}
				>
					<RefreshCw aria-hidden="true" />
					Try again
				</Button>
			</AlertDescription>
		</Alert>
	{:else if items.length === 0}
		<div
			class="flex flex-col items-center rounded-2xl border border-border bg-card px-6 py-12 text-center"
		>
			<Package class="mb-4 size-12 text-muted-foreground" aria-hidden="true" />
			<h2 class="text-lg font-semibold">
				{hasActiveFilters
					? "Nothing matches those filters"
					: "No equipment yet"}
			</h2>
			<p class="mt-1 text-sm text-muted-foreground">
				{hasActiveFilters
					? "Try a different search or clear the filters."
					: "Check back once the quartermasters add kit."}
			</p>
		</div>
	{:else}
		<p class="text-sm font-semibold text-foreground/70" aria-live="polite">
			{catalogQuery.data?.totalCount} item{catalogQuery.data?.totalCount === 1
				? ""
				: "s"}{catalogQuery.isFetching ? " · updating…" : ""}
		</p>
		<div class="grid gap-3 md:grid-cols-2">
			{#each items as item (item.id)}
				<a
					href="{LIST_PATH}/{item.slug}"
					class="inventory-card group block p-4 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring sm:p-5"
					onclick={(event) => {
						if (isModifiedClick(event)) return;
						event.preventDefault();
						openItem(item.slug, event.currentTarget);
					}}
				>
					<div class="flex gap-3">
						<div
							class="grid size-12 shrink-0 place-items-center rounded-xl bg-secondary/20 text-primary"
						>
							<Package class="size-6" aria-hidden="true" />
						</div>
						<div class="min-w-0 flex-1">
							<div class="flex items-start justify-between gap-3">
								<h2 class="font-semibold leading-snug">{item.label}</h2>
								<Badge
									variant={item.availability.available
										? "secondary"
										: "outline"}
									class="shrink-0"
								>
									{availabilityLabel(item.availability.reason)}
								</Badge>
							</div>
							<p class="mt-1 text-sm text-muted-foreground">
								{item.category?.name ?? "Uncategorized"}
							</p>
							<div
								class="mt-3 flex items-center justify-between gap-3 border-t pt-3"
							>
								<p class="font-mono text-xs text-muted-foreground">
									ID {item.slug}
								</p>
								<span
									class="flex items-center gap-1 text-sm font-semibold text-primary"
									>View item <ArrowRight
										class="size-4 transition-transform group-hover:translate-x-0.5"
										aria-hidden="true"
									/></span
								>
							</div>
						</div>
					</div>
				</a>
			{/each}
		</div>

		{#if cursor || catalogQuery.data?.nextCursor}
			<div class="mt-4 flex items-center justify-between gap-2">
				{#if catalogQuery.data?.previousCursor}
					<Button
						variant="outline"
						size="sm"
						class="min-h-11"
						onclick={() => {
							cursor = catalogQuery.data?.previousCursor ?? undefined;
						}}
					>
						Previous
					</Button>
				{:else}
					<span></span>
				{/if}
				{#if catalogQuery.data?.nextCursor}
					<Button
						variant="outline"
						size="sm"
						class="min-h-11"
						onclick={() => {
							cursor = catalogQuery.data?.nextCursor ?? undefined;
						}}
					>
						Next
					</Button>
				{/if}
			</div>
		{/if}
	{/if}
</div>

<Sheet.Root
	open={Boolean(selectedItemSlug)}
	onOpenChange={(open) => {
		if (!open) closeSheet();
	}}
	onOpenChangeComplete={(open) => {
		if (!open) selectedItemTrigger?.focus();
	}}
>
	<Sheet.Content
		side="bottom-right"
		class="max-h-[92svh] w-full max-w-none gap-0 overflow-hidden rounded-t-2xl p-0 sm:max-h-none sm:w-[40rem] sm:max-w-[calc(100vw-2rem)] sm:rounded-none"
	>
		<Sheet.Header class="sr-only">
			<Sheet.Title>Equipment details</Sheet.Title>
			<Sheet.Description>
				Review equipment details and choose request dates.
			</Sheet.Description>
		</Sheet.Header>
		<div
			class="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain px-5 pt-[max(1.5rem,env(safe-area-inset-top))] pb-[max(1.5rem,env(safe-area-inset-bottom))] sm:px-6 sm:py-6"
		>
			{#if selectedItemSlug}
				{#key selectedItemSlug}
					<MemberEquipmentItem slug={selectedItemSlug} />
				{/key}
			{/if}
		</div>
	</Sheet.Content>
</Sheet.Root>
