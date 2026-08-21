<script lang="ts">
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
	Funnel,
	TriangleAlert,
	FolderOpen,
	Tags,
} from "@lucide/svelte";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
import { page } from "$app/state";
import { Label } from "$lib/components/ui/label";
import { createQuery, keepPreviousData } from "@tanstack/svelte-query";
import {
	inventoryItemsIndexOptions,
	type InventoryItem as ApiInventoryItem,
} from "@dhc/api-client";
import type { InventoryAttributes } from "$lib/types";
import { parseInventoryAttributes } from "$lib/schemas/inventory";
import { SvelteURLSearchParams } from "svelte/reactivity";

let { data } = $props();

const PAGE_SIZE = 50;
const currentCursor = $derived(page.url.searchParams.get("cursor") || "");
let searchInput = $derived(page.url.searchParams.get("search") || "");
let categoryInput = $derived(page.url.searchParams.get("category") || "");
let containerInput = $derived(page.url.searchParams.get("container") || "");
let maintenanceInput = $derived(page.url.searchParams.get("maintenance") || "");

type InventoryItem = {
	id: string;
	quantity: number;
	out_for_maintenance: boolean;
	attributes: InventoryAttributes;
	category: { id?: string | null; name?: string | null } | null;
	container: { id?: string | null; name?: string | null } | null;
};

function toLegacyItem(item: ApiInventoryItem): InventoryItem {
	return {
		id: item.id,
		quantity: item.quantity,
		out_for_maintenance: item.outForMaintenance,
		attributes: parseInventoryAttributes(item.attributes ?? {}),
		category: item.category,
		container: item.container,
	};
}

const itemsQuery = createQuery(() => ({
	...inventoryItemsIndexOptions({
		query: {
			limit: PAGE_SIZE,
			cursor: currentCursor || undefined,
			search: searchInput || undefined,
			categoryId: categoryInput || undefined,
			containerId: containerInput || undefined,
			outForMaintenance: maintenanceInput
				? maintenanceInput === "true"
				: undefined,
		},
	}),
	placeholderData: keepPreviousData,
	select: (response) => ({
		items: response.data.items.map(toLegacyItem),
		nextCursor: response.data.nextCursor,
	}),
}));

const applyFilters = () => {
	const params = new SvelteURLSearchParams();
	if (searchInput) params.set("search", searchInput);
	if (categoryInput) params.set("category", categoryInput);
	if (containerInput) params.set("container", containerInput);
	if (maintenanceInput) params.set("maintenance", maintenanceInput);

	const url = `/dashboard/inventory/items?${params.toString()}`;
	goto(url);
};

const clearFilters = () => {
	goto(resolve("/dashboard/inventory/items"));
};

const goToNextPage = () => {
	if (!itemsQuery.data?.nextCursor) return;
	const params = new SvelteURLSearchParams(page.url.searchParams);
	params.set("cursor", itemsQuery.data.nextCursor);
	const url = `/dashboard/inventory/items?${params.toString()}`;
	goto(url);
};

const goToFirstPage = () => {
	const params = new SvelteURLSearchParams(page.url.searchParams);
	params.delete("cursor");
	const url = `/dashboard/inventory/items?${params.toString()}`;
	goto(url);
};

const getItemDisplayName = (item: InventoryItem) => {
	if (item.attributes?.name) return String(item.attributes.name);
	if (item.attributes?.brand && item.attributes?.type) {
		return `${String(item.attributes.brand)} ${String(item.attributes.type)}`;
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
				<Funnel class="h-5 w-5" />
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
							onkeydown={(e: KeyboardEvent) =>
								e.key === "Enter" && applyFilters()}
						/>
					</div>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium">Category</Label>
					<Select type="single" bind:value={categoryInput}>
						<SelectTrigger>
							{categoryInput
								? data.categories.find((c) => c.id === categoryInput)?.name
								: "All categories"}
						</SelectTrigger>
						<SelectContent>
							<SelectItem value="">All categories</SelectItem>
							{#each data.categories as category (category.id)}
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
								? data.containers.find((c) => c.id === containerInput)?.name
								: "All containers"}
						</SelectTrigger>
						<SelectContent>
							<SelectItem value="">All containers</SelectItem>
							{#each data.containers as container (container.id)}
								<SelectItem value={container.id}>{container.name}</SelectItem>
							{/each}
						</SelectContent>
					</Select>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium">Maintenance</Label>
					<Select type="single" bind:value={maintenanceInput}>
						<SelectTrigger>
							{maintenanceInput === "true"
								? "Out for maintenance"
								: maintenanceInput === "false"
									? "Available items"
									: "All items"}
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
							<Button onclick={clearFilters} variant="outline" size="sm"
								>Clear</Button
							>
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
				<TriangleAlert class="h-12 w-12 text-destructive mb-4" />
				<h3 class="text-lg font-semibold mb-2">Error loading items</h3>
				<p class="text-muted-foreground mb-4">
					{itemsQuery.error.errors?.detail || "Failed to load items"}
				</p>
				<Button onclick={() => itemsQuery.refetch()} variant="outline"
					>Retry</Button
				>
			</CardContent>
		</Card>
	{:else if itemsQuery.data.items.length === 0}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<Package class="h-12 w-12 text-muted-foreground mb-4" />
				<h3 class="text-lg font-semibold mb-2">
					{hasActiveFilters ? "No items match your filters" : "No items yet"}
				</h3>
				<p class="text-muted-foreground mb-4">
					{hasActiveFilters
						? "Try adjusting your search criteria"
						: "Add your first inventory item to get started"}
				</p>
				{#if hasActiveFilters}
					<Button onclick={clearFilters} variant="outline">Clear Filters</Button
					>
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
					Items ({itemsQuery.data.items.length})
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
					{#each itemsQuery.data.items as item (item.id)}
						<div
							class="flex items-center justify-between p-4 rounded-lg border hover:bg-muted/50 transition-colors"
						>
							<div class="flex items-center gap-4">
								<div
									class="flex h-10 w-10 items-center justify-center rounded-md bg-muted"
								>
									<Package class="h-5 w-5" />
								</div>

								<div class="flex-1">
									<div class="flex items-center gap-2 mb-1">
										<h3 class="font-medium">{getItemDisplayName(item)}</h3>
										{#if item.out_for_maintenance}
											<Badge
												variant="destructive"
												class="text-xs flex items-center gap-1"
											>
												<TriangleAlert class="h-3 w-3" />
												Maintenance
											</Badge>
										{/if}
									</div>

									<div
										class="flex items-center gap-3 text-sm text-muted-foreground"
									>
										<div class="flex items-center gap-1">
											<Tags class="h-3 w-3" />
											{item.category?.name || "Uncategorized"}
										</div>
										<div class="flex items-center gap-1">
											<FolderOpen class="h-3 w-3" />
											{item.container?.name || "No container"}
										</div>
										<Badge variant="outline" class="text-xs">
											Qty: {item.quantity}
										</Badge>
									</div>
								</div>
							</div>

							<div class="flex items-center gap-2">
								<Button
									href="/dashboard/inventory/items/{item.id}"
									variant="ghost"
									size="sm"
								>
									View
								</Button>
							</div>
						</div>
					{/each}
				</div>

				<!-- Cursor pagination -->
				{#if currentCursor || itemsQuery.data.nextCursor}
					<div class="flex items-center justify-between mt-6">
						<p class="text-sm text-muted-foreground">
							Showing up to {PAGE_SIZE} items per page
						</p>

						<div class="flex gap-2">
							{#if currentCursor}
								<Button onclick={goToFirstPage} variant="outline" size="sm">
									First page
								</Button>
							{/if}

							{#if itemsQuery.data.nextCursor}
								<Button onclick={goToNextPage} variant="outline" size="sm">
									Next
								</Button>
							{/if}
						</div>
					</div>
				{/if}
			</CardContent>
		</Card>
	{/if}
</div>
