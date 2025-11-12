<script lang="ts">
	import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import { Input } from '$lib/components/ui/input';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { Package, Plus, Search, Filter, AlertTriangle, FolderOpen, Tags } from 'lucide-svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { Label } from '$lib/components/ui/Label';

	let { data } = $props();

	let searchTerm = $state(data.filters.search || '');
	let selectedCategory = $state(data.filters.category || '');
	let selectedContainer = $state(data.filters.container || '');
	let selectedMaintenance = $state(data.filters.maintenance || '');

	const applyFilters = () => {
		const params = new URLSearchParams();
		if (searchTerm) params.set('search', searchTerm);
		if (selectedCategory) params.set('category', selectedCategory);
		if (selectedContainer) params.set('container', selectedContainer);
		if (selectedMaintenance) params.set('maintenance', selectedMaintenance);

		goto(`/dashboard/inventory/items?${params.toString()}`);
	};

	const clearFilters = () => {
		searchTerm = '';
		selectedCategory = '';
		selectedContainer = '';
		selectedMaintenance = '';
		goto('/dashboard/inventory/items');
	};

	const getItemDisplayName = (item: any) => {
		if (item.attributes?.name) return item.attributes.name;
		if (item.attributes?.brand && item.attributes?.type) {
			return `${item.attributes.brand} ${item.attributes.type}`;
		}
		return `${item.category?.name || 'Item'} #${item.id.slice(-8)}`;
	};

	const hasActiveFilters =
		searchTerm || selectedCategory || selectedContainer || selectedMaintenance;
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
							bind:value={searchTerm}
							placeholder="Search items..."
							class="pl-10"
							onkeydown={(e) => e.key === 'Enter' && applyFilters()}
						/>
					</div>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium">Category</Label>
					<Select type="single" bind:value={selectedCategory}>
						<SelectTrigger>
							{selectedCategory
								? data.categories.find((c) => c.id === selectedCategory)?.name
								: 'All categories'}
						</SelectTrigger>
						<SelectContent>
							<SelectItem value="">All categories</SelectItem>
							{#each data.categories as category}
								<SelectItem value={category.id}>{category.name}</SelectItem>
							{/each}
						</SelectContent>
					</Select>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium">Container</Label>
					<Select type="single" bind:value={selectedContainer}>
						<SelectTrigger>
							{selectedContainer
								? data.containers.find((c) => c.id === selectedContainer)?.name
								: 'All containers'}
						</SelectTrigger>
						<SelectContent>
							<SelectItem value="">All containers</SelectItem>
							{#each data.containers as container}
								<SelectItem value={container.id}>{container.name}</SelectItem>
							{/each}
						</SelectContent>
					</Select>
				</div>

				<div class="space-y-2">
					<Label class="text-sm font-medium">Maintenance</Label>
					<Select type="single" bind:value={selectedMaintenance}>
						<SelectTrigger>
							{selectedMaintenance === 'true'
								? 'Out for maintenance'
								: selectedMaintenance === 'false'
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
	{#if data.items.length === 0}
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
				<CardTitle>
					Items ({data.pagination.total})
					{#if hasActiveFilters}
						<Badge variant="secondary" class="ml-2">Filtered</Badge>
					{/if}
				</CardTitle>
			</CardHeader>
			<CardContent>
				<div class="space-y-3">
					{#each data.items as item}
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
										{#if item.out_for_maintenance}
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

				<!-- Pagination -->
				{#if data.pagination.totalPages > 1}
					<div class="flex items-center justify-between mt-6">
						<p class="text-sm text-muted-foreground">
							Showing {(data.pagination.page - 1) * data.pagination.limit + 1}
							to {Math.min(data.pagination.page * data.pagination.limit, data.pagination.total)}
							of {data.pagination.total} items
						</p>

						<div class="flex gap-2">
							{#if data.pagination.page > 1}
								<Button
									href="?{new URLSearchParams({
										...page.url.searchParams,
										page: (data.pagination.page - 1).toString()
									}).toString()}"
									variant="outline"
									size="sm"
								>
									Previous
								</Button>
							{/if}

							{#if data.pagination.page < data.pagination.totalPages}
								<Button
									href="?{new URLSearchParams({
										...page.url.searchParams,
										page: (data.pagination.page + 1).toString()
									}).toString()}"
									variant="outline"
									size="sm"
								>
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
