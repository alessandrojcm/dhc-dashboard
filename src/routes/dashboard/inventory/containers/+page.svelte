<script lang="ts">
import type { SupabaseClient } from "@supabase/supabase-js";
import { createQuery } from "@tanstack/svelte-query";
import type { Database } from "$database";

const { data } = $props();
const supabase: SupabaseClient<Database> = data.supabase;

// Fetch containers with TanStack Query
const containersQuery = createQuery(() => ({
	queryKey: ["inventory-containers"],
	queryFn: async ({ signal }) => {
		const { data: containers, error } = await supabase
			.from("containers")
			.select(
				"id, name, description, parent_container_id, parent_container:containers!containers_parent_container_id_fkey(id, name), item_count:equipment_items(count)",
			)
			.order("name")
			.abortSignal(signal);

		if (error) throw error;

		return containers || [];
	},
}));

// Build hierarchy tree
const buildHierarchy = (containers: any[]) => {
	const containerMap = new Map();
	const rootContainers: any[] = [];

	// First pass: create map of all containers
	containers.forEach((container) => {
		containerMap.set(container.id, { ...container, children: [] });
	});

	// Second pass: build hierarchy
	containers.forEach((container) => {
		if (container.parent_container_id) {
			const parent = containerMap.get(container.parent_container_id);
			if (parent) {
				parent.children.push(containerMap.get(container.id));
			}
		} else {
			rootContainers.push(containerMap.get(container.id));
		}
	});

	return rootContainers;
};

const renderContainer = (container: any, level = 0) => {
	const itemCount = container.item_count?.[0]?.count || 0;
	const hasChildren = container.children.length > 0;

	return {
		container,
		level,
		itemCount,
		hasChildren,
	};
};

const flattenHierarchy = (containers: any[], level = 0): any[] => {
	const result: any[] = [];
	containers.forEach((container) => {
		result.push(renderContainer(container, level));
		if (container.children.length > 0) {
			result.push(...flattenHierarchy(container.children, level + 1));
		}
	});
	return result;
};

const hierarchy = $derived(
	containersQuery.data ? buildHierarchy(containersQuery.data) : [],
);
const _flatContainers = $derived(flattenHierarchy(hierarchy));
</script>

<div class="p-6">
	<div class="flex items-center justify-between mb-6">
		<div>
			<h1 class="text-3xl font-bold">Containers</h1>
			<p class="text-muted-foreground">Manage storage locations and hierarchy</p>
		</div>
		{#if data.canEdit}
			<Button href="/dashboard/inventory/containers/create">
				<Plus class="mr-2 h-4 w-4" />
				Add Container
			</Button>
		{/if}
	</div>

	{#if containersQuery.isPending}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<LoaderCircle />
				<p class="text-muted-foreground mt-4">Loading containers...</p>
			</CardContent>
		</Card>
	{:else if containersQuery.isError}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<AlertTriangle class="h-12 w-12 text-destructive mb-4" />
				<h3 class="text-lg font-semibold mb-2">Error loading containers</h3>
				<p class="text-muted-foreground mb-4">{containersQuery.error.message}</p>
				<Button onclick={() => containersQuery.refetch()} variant="outline">Retry</Button>
			</CardContent>
		</Card>
	{:else if flatContainers.length === 0 && data.canEdit}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<FolderOpen class="h-12 w-12 text-muted-foreground mb-4" />
				<h3 class="text-lg font-semibold mb-2">No containers yet</h3>
				<p class="text-muted-foreground mb-4">
					Create your first container to start organizing your inventory
				</p>
				<Button href="/dashboard/inventory/containers/create">
					<Plus class="mr-2 h-4 w-4" />
					Create Container
				</Button>
			</CardContent>
		</Card>
	{:else}
		<Card>
			<CardHeader>
				<CardTitle>Container Hierarchy</CardTitle>
			</CardHeader>
			<CardContent>
				<div class="space-y-2">
					{#each flatContainers as { container, level, itemCount, hasChildren } (container.id)}
						<div
							class="flex items-center gap-3 p-3 rounded-lg border hover:bg-muted/50 transition-colors"
						>
							<!-- Indentation for hierarchy -->
							<div
								data-testid="container-hierarchy"
								style="margin-left: {level * 24}px"
								class="flex items-center gap-3 flex-1"
							>
								<div class="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
									<FolderOpen class="h-4 w-4" />
								</div>

								<div class="flex-1">
									<div class="flex items-center gap-2">
										<h3 class="font-medium">{container.name}</h3>
										{#if hasChildren}
											<Badge variant="secondary" class="text-xs">
												{container.children.length} child{container.children.length !== 1
													? 'ren'
													: ''}
											</Badge>
										{/if}
									</div>
									{#if container.description}
										<p class="text-sm text-muted-foreground">{container.description}</p>
									{/if}
									{#if container.parent_container}
										<p class="text-xs text-muted-foreground">
											Parent: {container.parent_container.name}
										</p>
									{/if}
								</div>

								<div class="flex items-center gap-2">
									<Badge variant="outline" class="flex items-center gap-1">
										<Package class="h-3 w-3" />
										{itemCount} item{itemCount !== 1 ? 's' : ''}
									</Badge>

									<Button
										aria-label={`View ${container.name}`}
										href="/dashboard/inventory/containers/{container.id}"
										variant="ghost"
										size="sm"
									>
										View
									</Button>
									{#if data.canEdit}
										<Button
											aria-label={`Edit ${container.name}`}
											href="/dashboard/inventory/containers/{container.id}/edit"
											variant="ghost"
											size="sm"
										>
											<Edit class="h-4 w-4" />
										</Button>
									{/if}
								</div>
							</div>
						</div>
					{/each}
				</div>
			</CardContent>
		</Card>
	{/if}
</div>
