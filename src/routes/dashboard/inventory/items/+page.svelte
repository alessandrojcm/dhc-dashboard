<script lang="ts">
    import type {Database} from '$database';
    import type {SupabaseClient} from '@supabase/supabase-js';
    import {Card, CardContent, CardHeader, CardTitle} from '$lib/components/ui/card';
    import {Button} from '$lib/components/ui/button';
    import {Badge} from '$lib/components/ui/badge';
    import {Input} from '$lib/components/ui/input';
    import {Select, SelectContent, SelectItem, SelectTrigger} from '$lib/components/ui/select';
    import {Package, Plus, Search, Filter, AlertTriangle, FolderOpen, Tags} from 'lucide-svelte';
    import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
    import {goto} from '$app/navigation';
    import {page} from '$app/state';
    import {Label} from '$lib/components/ui/label';
    import {createQuery, keepPreviousData} from '@tanstack/svelte-query';
    import type {InventoryItem, InventoryItemWithRelations} from "$lib/types";

    let {data} = $props();
    const supabase: SupabaseClient<Database> = data.supabase;

    const PAGE_SIZE = 20;

    // Parse URL params
    const currentPage = $derived(Number(page.url.searchParams.get('page')) || 1);
    let searchInput = $derived(page.url.searchParams.get('search') || '');
    let categoryInput = $derived(page.url.searchParams.get('category') || '');
    let containerInput = $derived(page.url.searchParams.get('container') || '');
    let maintenanceInput = $derived(page.url.searchParams.get('maintenance') || '');

    type InventoryItem = Pick<InventoryItemWithRelations, 'id' | 'quantity' | 'out_for_maintenance' | 'attributes' | 'category' | 'container'>

    async function getItems(signal: AbortSignal) {
        let query = supabase
            .from('inventory_items')
            .select(
                'id, quantity, out_for_maintenance, attributes, category:equipment_categories(id, name), container:containers(id, name)',
                {count: 'exact'}
            );
        // Apply filters
        if (searchInput) {
            // Search in attributes->name, category name, or container name
            query = query.or(
                `attributes->name.ilike.%${searchInput}%,equipment_categories.name.ilike.%${searchInput}%,containers.name.ilike.%${searchInput}%`
            );
        }
        if (categoryInput) {
            query = query.eq('category_id', categoryInput);
        }
        if (containerInput) {
            query = query.eq('container_id', containerInput);
        }
        if (maintenanceInput) {
            query = query.eq('out_for_maintenance', maintenanceInput === 'true');
        }

        // Pagination
        const rangeStart = (currentPage - 1) * PAGE_SIZE;
        const rangeEnd = rangeStart + PAGE_SIZE - 1;

        const {
            data: items,
            error,
            count
        } = await query
            .range(rangeStart, rangeEnd)
            .order('created_at', {ascending: false})
            .throwOnError()
            .abortSignal(signal);

        if (error) throw error;

        return {
            items: (items || []) as InventoryItem[],
            total: count || 0,
            totalPages: Math.ceil((count || 0) / PAGE_SIZE)
        };
    }

    // Fetch items with TanStack Query
    const itemsQuery = createQuery(() => ({
        queryKey: [
            'inventory-items',
            currentPage,
            searchInput,
            categoryInput,
            containerInput,
            maintenanceInput
        ],
        placeholderData: keepPreviousData,
        queryFn: async ({signal}) => {
            return getItems(signal);
        }
    }));

    const applyFilters = () => {
        const params = new URLSearchParams();
        if (searchInput) params.set('search', searchInput);
        if (categoryInput) params.set('category', categoryInput);
        if (containerInput) params.set('container', containerInput);
        if (maintenanceInput) params.set('maintenance', maintenanceInput);
        params.set('page', '1'); // Reset to page 1 on filter change

        goto(`/dashboard/inventory/items?${params.toString()}`);
    };

    const clearFilters = () => {
        goto('/dashboard/inventory/items');
    };

    const goToPage = (pageNum: number) => {
        const params = new URLSearchParams(page.url.searchParams);
        params.set('page', pageNum.toString());
        goto(`/dashboard/inventory/items?${params.toString()}`);
    };

    const getItemDisplayName = (item: InventoryItem) => {
        if (item.attributes?.name) return item.attributes.name;
        if (item.attributes?.brand && item.attributes?.type) {
            return `${item.attributes.brand} ${item.attributes.type}`;
        }
        return `${item.category?.name || 'Item'} #${item.id.slice(-8)}`;
    };

    const hasActiveFilters = $derived(
        searchInput || categoryInput || containerInput || maintenanceInput
    );
</script>

<div class="p-6">
    <div class="flex items-center justify-between mb-6">
        <div>
            <h1 class="text-3xl font-bold">Inventory Items</h1>
            <p class="text-muted-foreground">Browse and manage all equipment items</p>
        </div>
        <Button href="/dashboard/inventory/items/create">
            <Plus class="mr-2 h-4 w-4"/>
            Add Item
        </Button>
    </div>

    <!-- Filters -->
    <Card class="mb-6">
        <CardHeader>
            <CardTitle class="flex items-center gap-2">
                <Filter class="h-5 w-5"/>
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
                                ? data.categories.find((c) => c.id === categoryInput)?.name
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
                    <Select type="single" bind:value={containerInput}>
                        <SelectTrigger>
                            {containerInput
                                ? data.containers.find((c) => c.id === containerInput)?.name
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
                <LoaderCircle/>
                <p class="text-muted-foreground mt-4">Loading items...</p>
            </CardContent>
        </Card>
    {:else if itemsQuery.isError}
        <Card>
            <CardContent class="flex flex-col items-center justify-center py-12">
                <AlertTriangle class="h-12 w-12 text-destructive mb-4"/>
                <h3 class="text-lg font-semibold mb-2">Error loading items</h3>
                <p class="text-muted-foreground mb-4">{itemsQuery.error.message}</p>
                <Button onclick={() => itemsQuery.refetch()} variant="outline">Retry</Button>
            </CardContent>
        </Card>
    {:else if itemsQuery.data.items.length === 0}
        <Card>
            <CardContent class="flex flex-col items-center justify-center py-12">
                <Package class="h-12 w-12 text-muted-foreground mb-4"/>
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
                        <Plus class="mr-2 h-4 w-4"/>
                        Add First Item
                    </Button>
                {/if}
            </CardContent>
        </Card>
    {:else}
        <Card>
            <CardHeader>
                <CardTitle class="flex items-center gap-2">
                    Items ({itemsQuery.data.total})
                    {#if hasActiveFilters}
                        <Badge variant="secondary" class="ml-2">Filtered</Badge>
                    {/if}
                    {#if itemsQuery.isFetching}
                        <LoaderCircle/>
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
                                <div class="flex h-10 w-10 items-center justify-center rounded-md bg-muted">
                                    <Package class="h-5 w-5"/>
                                </div>

                                <div class="flex-1">
                                    <div class="flex items-center gap-2 mb-1">
                                        <h3 class="font-medium">{getItemDisplayName(item)}</h3>
                                        {#if item.out_for_maintenance}
                                            <Badge variant="destructive" class="text-xs flex items-center gap-1">
                                                <AlertTriangle class="h-3 w-3"/>
                                                Maintenance
                                            </Badge>
                                        {/if}
                                    </div>

                                    <div class="flex items-center gap-3 text-sm text-muted-foreground">
                                        <div class="flex items-center gap-1">
                                            <Tags class="h-3 w-3"/>
                                            {item.category?.name || 'Uncategorized'}
                                        </div>
                                        <div class="flex items-center gap-1">
                                            <FolderOpen class="h-3 w-3"/>
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
                {#if itemsQuery.data.totalPages > 1}
                    <div class="flex items-center justify-between mt-6">
                        <p class="text-sm text-muted-foreground">
                            Showing {(currentPage - 1) * PAGE_SIZE + 1}
                            to {Math.min(currentPage * PAGE_SIZE, itemsQuery.data.total)}
                            of {itemsQuery.data.total} items
                        </p>

                        <div class="flex gap-2">
                            {#if currentPage > 1}
                                <Button onclick={() => goToPage(currentPage - 1)} variant="outline" size="sm">
                                    Previous
                                </Button>
                            {/if}

                            {#if currentPage < itemsQuery.data.totalPages}
                                <Button onclick={() => goToPage(currentPage + 1)} variant="outline" size="sm">
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
