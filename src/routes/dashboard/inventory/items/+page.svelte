<script lang="ts">
/* eslint-disable @typescript-eslint/no-explicit-any */
import {
	type InventoryItem,
	inventoryFiltersOptions,
	inventoryItemsOptions,
} from "@dhc/api-client";
import {
	Card,
	CardContent,
	CardHeader,
	CardTitle,
} from "$lib/components/ui/card";
import { Button } from "$lib/components/ui/button";
import { Badge } from "$lib/components/ui/badge";
import { Input } from "$lib/components/ui/input";
import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
} from "$lib/components/ui/select";
import {
	Package,
	Plus,
	Search,
	Filter,
	AlertTriangle,
	FolderOpen,
	Tags,
} from "lucide-svelte";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
import { page } from "$app/state";
import { Label } from "$lib/components/ui/label";
import { createQuery, keepPreviousData } from "@tanstack/svelte-query";

// PAGE_SIZE must be one of the OpenAPI limit enum values (10/25/50/100).
// The previous Supabase read used 20; 25 is the closest allowed value.
const PAGE_SIZE = 25 as const;

// Parse URL params. `cursor` is the opaque forward/backward pagination
// token returned by Phoenix; the page reset on filter change drops it.
const cursorInput = $derived(page.url.searchParams.get("cursor") || "");
let searchInput = $derived(page.url.searchParams.get("search") || "");
let categoryInput = $derived(page.url.searchParams.get("category") || "");
let containerInput = $derived(page.url.searchParams.get("container") || "");
let maintenanceInput = $derived(
	page.url.searchParams.get("maintenance") || "",
);

// Filter dropdown options (categories + containers) come from Phoenix via
// `@dhc/api-client` (issue ALE-98). Browser-direct, mirroring the overview
// counts + activity feed pattern; authz is enforced by Phoenix's
// `inventory_admin_api` pipeline.
const filtersQuery = createQuery(() => inventoryFiltersOptions());
const categories = $derived(filtersQuery.data?.data.categories ?? []);
const containers = $derived(filtersQuery.data?.data.containers ?? []);

// Inventory Item rows come from Phoenix (`GET /api/inventory/items`, issue
// ALE-99) via the generated TanStack Query options. Browser-direct,
// mirroring the overview/activity/filters/categories/containers pattern;
// authz is enforced by Phoenix's `inventory_admin_api` pipeline. Replaces
// the client-side Supabase/PostgREST read over `inventory_items` (joined to
// `equipment_categories` and `containers`).
//
// The endpoint is cursor-paginated (`createdAt desc, id desc`) with a
// `totalCount`; the query key binds the active filters + cursor so cache
// invalidation tracks filter/page changes.
const itemsQuery = createQuery(() => ({
	...inventoryItemsOptions({
		query: {
			limit: PAGE_SIZE,
			cursor: cursorInput || undefined,
			q: searchInput || undefined,
			categoryId: categoryInput || undefined,
			containerId: containerInput || undefined,
			// The UI uses "" / "true" / "false"; map to the domain terms.
			maintenanceStatus: maintenanceToApi(maintenanceInput),
		},
	}),
	placeholderData: keepPreviousData,
}));

const items = $derived(itemsQuery.data?.data.items ?? []);
const total = $derived(itemsQuery.data?.data.totalCount ?? 0);
const nextCursor = $derived(itemsQuery.data?.data.nextCursor ?? null);
const previousCursor = $derived(
	itemsQuery.data?.data.previousCursor ?? null,
);

// The old page count is no longer known (cursor pagination), but the
// footer can show a windowed count from the current page + total.
const pageStart = $derived(items.length === 0 ? 0 : 1);
const pageEnd = $derived(items.length);

function maintenanceToApi(value: string): "all" | "inMaintenance" | "available" | undefined {
	if (value === "true") return "inMaintenance";
	if (value === "false") return "available";
	return undefined;
}

const applyFilters = () => {
	// eslint-disable-next-line svelte/prefer-svelte-reactivity
	const params = new URLSearchParams();
	if (searchInput) params.set("search", searchInput);
	if (categoryInput) params.set("category", categoryInput);
	if (containerInput) params.set("container", containerInput);
	if (maintenanceInput) params.set("maintenance", maintenanceInput);
	// Filter change resets to the first page (no cursor).
	const url = `/dashboard/inventory/items?${params.toString()}`;
	goto(resolve(url as any));
};

const clearFilters = () => {
	goto(resolve("/dashboard/inventory/items"));
};

const goToNext = () => {
	// eslint-disable-next-line svelte/prefer-svelte-reactivity
	const params = buildParamsFromCurrent();
	if (nextCursor) params.set("cursor", nextCursor);
	const url = `/dashboard/inventory/items?${params.toString()}`;
	goto(resolve(url as any));
};

const goToPrevious = () => {
	// eslint-disable-next-line svelte/prefer-svelte-reactivity
	const params = buildParamsFromCurrent();
	if (previousCursor) params.set("cursor", previousCursor);
	const url = `/dashboard/inventory/items?${params.toString()}`;
	goto(resolve(url as any));
};

function buildParamsFromCurrent(): URLSearchParams {
	// eslint-disable-next-line svelte/prefer-svelte-reactivity
	const params = new URLSearchParams();
	if (searchInput) params.set("search", searchInput);
	if (categoryInput) params.set("category", categoryInput);
	if (containerInput) params.set("container", containerInput);
	if (maintenanceInput) params.set("maintenance", maintenanceInput);
	return params;
}

const getItemDisplayName = (item: InventoryItem) => {
	if (item.attributes?.name) return item.attributes.name as string;
	if (
		item.attributes?.brand &&
		item.attributes?.type
	) {
		return `${item.attributes.brand as string} ${
			item.attributes.type as string
		}`;
	}
	return `${item.category?.name || "Item"} #${item.id.slice(-8)}`;
};

const hasActiveFilters = $derived(
	searchInput || categoryInput || containerInput || maintenanceInput,
);
</script>

<div class="p-6">
	<div class="flex items-center justify-between mb-6">
		<div>
			<h1 class="text-3xl font-bold">Inventory Items</h1>
			<p class="text-muted-foreground">Browse and manage all equipment items</p>
		</div>
		<Button href="/dashboard/inventory/items/create">
			<Plus class="mr-2 h-4 w-4" />
			Add Item
		</Button>
	</div>

	<!-- Filters -->
	<Card class="mb-6">
		<CardHeader>
			<CardTitle class="flex items-center gap-2">
				<Filter class="h-5 w-5" />
				Filters
			</CardTitle>
		</CardHeader>
		<CardContent>
			<div class="grid gap-4 md:grid-cols-2 lg:grid-cols-5">
				<div class="space-y-2">
					<Label class="text-sm font-medium">Search</Label>
					<div class="relative">
						<Search
							class="absolute left-3 top-1/2 transform -translate-y-1/2 h-4 w-4 text-muted-foreground"
						/>
						<Input
							bind:value={searchInput}
							placeholder="Search items..."
							class="pl-10"
							onkeydown={(e: KeyboardEvent) => e.key === 'Enter' && applyFilters()}
						/>
					</div>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium">Category</Label>
					<Select type="single" bind:value={categoryInput}>
						<SelectTrigger>
					{categoryInput
						? categories.find((c) => c.id === categoryInput)?.name
						: 'All categories'}
					</SelectTrigger>
					<SelectContent>
						<SelectItem value="">All categories</SelectItem>
						{#each categories as category (category.id)}
								<SelectItem value={category.id}>{category.name}</SelectItem>
							{/each}
						</SelectContent>
					</Select>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium">Container</Label>
					<Select type="single" bind:value={containerInput}>
						<SelectTrigger>
					{containerInput
						? containers.find((c) => c.id === containerInput)?.name
						: 'All containers'}
					</SelectTrigger>
					<SelectContent>
						<SelectItem value="">All containers</SelectItem>
						{#each containers as container (container.id)}
								<SelectItem value={container.id}>{container.name}</SelectItem>
							{/each}
						</SelectContent>
					</Select>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium">Maintenance</Label>
					<Select type="single" bind:value={maintenanceInput}>
						<SelectTrigger>
							{maintenanceInput === 'true'
								? 'Out for maintenance'
								: maintenanceInput === 'false'
									? 'Available items'
									: 'All items'}
						</SelectTrigger>
						<SelectContent>
							<SelectItem value="">All items</SelectItem>
							<SelectItem value="false">Available items</SelectItem>
							<SelectItem value="true">Out for maintenance</SelectItem>
						</SelectContent>
					</Select>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium invisible">Actions</Label>
					<div class="flex gap-2">
						<Button onclick={applyFilters} size="sm">Apply</Button>
						{#if hasActiveFilters}
							<Button onclick={clearFilters} variant="outline" size="sm">Clear</Button>
						{/if}
					</div>
				</div>
			</div>
		</CardContent>
	</Card>

	<!-- Results -->
	{#if itemsQuery.isPending}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<LoaderCircle />
				<p class="text-muted-foreground mt-4">Loading items...</p>
			</CardContent>
		</Card>
			{:else if itemsQuery.isError}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<AlertTriangle class="h-12 w-12 text-destructive mb-4" />
				<h3 class="text-lg font-semibold mb-2">Error loading items</h3>
				<p class="text-muted-foreground mb-4">
					{(itemsQuery.error as Error)?.message ?? "Unknown error"}
				</p>
				<Button onclick={() => itemsQuery.refetch()} variant="outline">Retry</Button>
			</CardContent>
		</Card>
	{:else if items.length === 0}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<Package class="h-12 w-12 text-muted-foreground mb-4" />
				<h3 class="text-lg font-semibold mb-2">
					{hasActiveFilters ? 'No items match your filters' : 'No items yet'}
				</h3>
				<p class="text-muted-foreground mb-4">
					{hasActiveFilters
						? 'Try adjusting your search criteria'
						: 'Add your first inventory item to get started'}
				</p>
				{#if hasActiveFilters}
					<Button onclick={clearFilters} variant="outline">Clear Filters</Button>
				{:else}
					<Button href="/dashboard/inventory/items/create">
						<Plus class="mr-2 h-4 w-4" />
						Add First Item
					</Button>
				{/if}
			</CardContent>
		</Card>
	{:else}
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					Items ({total})
					{#if hasActiveFilters}
						<Badge variant="secondary" class="ml-2">Filtered</Badge>
					{/if}
					{#if itemsQuery.isFetching}
						<LoaderCircle />
					{/if}
				</CardTitle>
			</CardHeader>
			<CardContent>
				<div class="space-y-3">
					{#each items as item (item.id)}
						<div
							class="flex items-center justify-between p-4 rounded-lg border hover:bg-muted/50 transition-colors"
						>
							<div class="flex items-center gap-4">
								<div class="flex h-10 w-10 items-center justify-center rounded-md bg-muted">
									<Package class="h-5 w-5" />
								</div>

								<div class="flex-1">
									<div class="flex items-center gap-2 mb-1">
										<h3 class="font-medium">{getItemDisplayName(item)}</h3>
										{#if item.maintenanceStatus === 'inMaintenance'}
											<Badge variant="destructive" class="text-xs flex items-center gap-1">
												<AlertTriangle class="h-3 w-3" />
												Maintenance
											</Badge>
										{/if}
									</div>

									<div class="flex items-center gap-3 text-sm text-muted-foreground">
										<div class="flex items-center gap-1">
											<Tags class="h-3 w-3" />
											{item.category?.name || 'Uncategorized'}
										</div>
										<div class="flex items-center gap-1">
											<FolderOpen class="h-3 w-3" />
											{item.container?.name || 'No container'}
										</div>
										<Badge variant="outline" class="text-xs">
											Qty: {item.quantity}
										</Badge>
									</div>
								</div>
							</div>

							<div class="flex items-center gap-2">
								<Button href="/dashboard/inventory/items/{item.id}" variant="ghost" size="sm">
									View
								</Button>
							</div>
						</div>
					{/each}
				</div>

				<!-- Pagination (cursor-based) -->
				{#if nextCursor || previousCursor}
					<div class="flex items-center justify-between mt-6">
						<p class="text-sm text-muted-foreground">
							Showing {pageStart} to {pageEnd} of {total} items
						</p>

						<div class="flex gap-2">
							{#if previousCursor}
								<Button onclick={goToPrevious} variant="outline" size="sm">
									Previous
								</Button>
							{/if}

							{#if nextCursor}
								<Button onclick={goToNext} variant="outline" size="sm">
									Next
								</Button>
							{/if}
						</div>
					</div>
				{:else if total > items.length}
					<!-- Cursorless single page that still has more: unlikely but defensive. -->
					<p class="text-sm text-muted-foreground mt-6">
						Showing {pageStart} to {pageEnd} of {total} items
					</p>
				{/if}
			</CardContent>
		</Card>
	{/if}
</div>