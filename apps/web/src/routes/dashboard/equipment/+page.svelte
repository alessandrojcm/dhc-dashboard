<script lang="ts">
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
import { Package, Search, RefreshCw } from "@lucide/svelte";
import {
	inventoryCatalogListItemsOptions,
	inventoryCategoriesIndexOptions,
} from "@dhc/api-client";

// ALE-288 member browse (ALE-280 story 58): the browse half of the
// browse-decide-request-collect journey. Reads the member catalog only —
// label, slug, category, values, and the generic availability reason — so
// no container, note, or maintenance fact can reach this view.

type AvailabilityFilter = "all" | "available" | "unavailable";

const PAGE_SIZE = 25;

let searchInput = $state("");
let appliedSearch = $state<string | undefined>(undefined);
let categoryInput = $state("");
let availability = $state<AvailabilityFilter>("all");
let cursor = $state<string | undefined>(undefined);

const categoriesQuery = createQuery(() => ({
	...inventoryCategoriesIndexOptions(),
	select: (response) => response.data.categories,
}));

const catalogQuery = createQuery(() => ({
	...inventoryCatalogListItemsOptions({
		query: {
			limit: PAGE_SIZE,
			q: appliedSearch,
			categoryId: categoryInput || undefined,
			availability,
			cursor,
		},
	}),
	placeholderData: keepPreviousData,
	select: (response) => response.data,
}));

const items = $derived(catalogQuery.data?.items ?? []);
const hasActiveFilters = $derived(
	appliedSearch || categoryInput || availability !== "all",
);

function applySearch() {
	const trimmed = searchInput.trim();
	appliedSearch = trimmed ? trimmed : undefined;
	cursor = undefined;
}

function onFilterChange() {
	cursor = undefined;
}

function clearFilters() {
	searchInput = "";
	appliedSearch = undefined;
	categoryInput = "";
	availability = "all";
	cursor = undefined;
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

<div class="mx-auto max-w-md px-4 pt-5 pb-10 sm:max-w-2xl sm:px-5">
	<header class="mb-5">
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Member inventory
		</p>
		<h1 class="font-heading text-2xl font-bold sm:text-3xl">
			Find the right kit
		</h1>
		<p class="mt-1 text-sm text-muted-foreground">
			Browse lendable equipment. Storage appears only when a request is
			approved.
		</p>
	</header>

	<form
		class="relative mb-3"
		onsubmit={(e) => {
			e.preventDefault();
			applySearch();
		}}
	>
		<Label for="equipment-search" class="sr-only">Search items</Label>
		<Search
			class="absolute left-4 top-1/2 size-5 -translate-y-1/2 text-muted-foreground"
		/>
		<Input
			id="equipment-search"
			class="h-12 pl-11 text-base"
			placeholder="Search swords, masks, size…"
			bind:value={searchInput}
		/>
	</form>

	<div class="mb-3 grid grid-cols-2 gap-2">
		<div class="space-y-1">
			<Label class="text-xs font-medium">Category</Label>
			<Select
				type="single"
				bind:value={categoryInput}
				onValueChange={onFilterChange}
			>
				<SelectTrigger class="min-h-11">
					{categoryInput
						? (categoriesQuery.data?.find((c) => c.id === categoryInput)
								?.name ?? "Category")
						: "All categories"}
				</SelectTrigger>
				<SelectContent>
					<SelectItem value="">All categories</SelectItem>
					{#each categoriesQuery.data ?? [] as category (category.id)}
						<SelectItem value={category.id}>{category.name}</SelectItem>
					{/each}
				</SelectContent>
			</Select>
		</div>
		<div class="space-y-1">
			<Label class="text-xs font-medium">Availability</Label>
			<Select
				type="single"
				bind:value={availability}
				onValueChange={() => onFilterChange()}
			>
				<SelectTrigger class="min-h-11">
					{availability === "all"
						? "Everything"
						: availability === "available"
							? "Available now"
							: "Unavailable"}
				</SelectTrigger>
				<SelectContent>
					<SelectItem value="all">Everything</SelectItem>
					<SelectItem value="available">Available now</SelectItem>
					<SelectItem value="unavailable">Unavailable</SelectItem>
				</SelectContent>
			</Select>
		</div>
	</div>

	{#if hasActiveFilters}
		<div class="mb-4">
			<Button
				variant="outline"
				size="sm"
				class="min-h-10"
				onclick={clearFilters}
			>
				Clear filters
			</Button>
		</div>
	{/if}

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
			{#if hasActiveFilters}
				<Button variant="outline" class="mt-4 min-h-11" onclick={clearFilters}>
					Clear filters
				</Button>
			{/if}
		</div>
	{:else}
		<p class="mb-2 text-sm text-muted-foreground" aria-live="polite">
			{catalogQuery.data?.totalCount} item{catalogQuery.data?.totalCount === 1
				? ""
				: "s"}{catalogQuery.isFetching ? " · updating…" : ""}
		</p>
		<div class="space-y-3">
			{#each items as item (item.id)}
				<a
					href="/dashboard/equipment/{item.slug}"
					class="block rounded-2xl border border-border bg-card p-4 shadow-sm transition-colors hover:bg-muted/40 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
				>
					<div class="flex gap-3">
						<div
							class="grid size-12 shrink-0 place-items-center rounded-xl bg-secondary/20 text-primary"
						>
							<Package class="size-6" aria-hidden="true" />
						</div>
						<div class="min-w-0 flex-1">
							<div class="flex items-start justify-between gap-2">
								<h2 class="font-semibold">{item.label}</h2>
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
							<p class="mt-2 font-mono text-xs text-muted-foreground">
								ID {item.slug}
							</p>
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
