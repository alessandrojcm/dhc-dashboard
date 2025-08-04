<script lang="ts">
	import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import {
		ArrowLeft,
		FolderOpen,
		Edit,
		Plus,
		Package,
		Folder,
		AlertTriangle
	} from 'lucide-svelte';
	import dayjs from 'dayjs';

	let { data } = $props();
	const { container } = data;

	const getItemDisplayName = (item: any) => {
		if (item.attributes?.name) return item.attributes.name;
		if (item.attributes?.brand && item.attributes?.type) {
			return `${item.attributes.brand} ${item.attributes.type}`;
		}
		return `${item.category?.name || 'Item'} #${item.id.slice(-8)}`;
	};
</script>

<div class="p-6">
	<div class="mb-6">
		<div class="flex items-center gap-2 mb-2">
			<Button href="/dashboard/inventory/containers" variant="ghost" size="sm">
				<ArrowLeft class="h-4 w-4" />
			</Button>
			<h1 class="text-3xl font-bold">{container.name}</h1>
		</div>
		<p class="text-muted-foreground">Container details and contents</p>
	</div>

	<div class="grid gap-6 lg:grid-cols-3">
		<!-- Container Info -->
		<div class="lg:col-span-1">
			<Card>
				<CardHeader>
					<CardTitle class="flex items-center gap-2">
						<FolderOpen class="h-5 w-5" />
						Container Information
					</CardTitle>
				</CardHeader>
				<CardContent class="space-y-4">
					<div>
						<h3 class="font-medium">Name</h3>
						<p class="text-sm text-muted-foreground">{container.name}</p>
					</div>

					{#if container.description}
						<div>
							<h3 class="font-medium">Description</h3>
							<p class="text-sm text-muted-foreground">{container.description}</p>
						</div>
					{/if}

					{#if container.parent_container}
						<div>
							<h3 class="font-medium">Parent Container</h3>
							<Button
								href="/dashboard/inventory/containers/{container.parent_container.id}"
								variant="link"
								class="p-0 h-auto text-sm"
							>
								{container.parent_container.name}
							</Button>
						</div>
					{/if}

					<div>
						<h3 class="font-medium">Created</h3>
						<p class="text-sm text-muted-foreground">
							{dayjs(container.created_at).format('MMM D, YYYY')}
						</p>
					</div>

					{#if data.canEdit}
						<div class="flex gap-2 pt-4">
							<Button href="/dashboard/inventory/containers/{container.id}/edit" size="sm">
								<Edit class="mr-2 h-4 w-4" />
								Edit
							</Button>
						</div>
					{/if}
				</CardContent>
			</Card>
		</div>

		<!-- Contents -->
		<div class="lg:col-span-2 space-y-6">
			<!-- Child Containers -->
			{#if container.child_containers && container.child_containers.length > 0}
				<Card>
					<CardHeader>
						<CardTitle class="flex items-center justify-between">
							<span class="flex items-center gap-2">
								<Folder class="h-5 w-5" />
								Child Containers ({container.child_containers.length})
							</span>
							{#if data.canEdit}
								<Button href="/dashboard/inventory/containers/create?parent={container.id}" size="sm">
									<Plus class="mr-2 h-4 w-4" />
									Add Child
								</Button>
							{/if}
						</CardTitle>
					</CardHeader>
					<CardContent>
						<div class="space-y-2">
							{#each container.child_containers as child}
								<div
									class="flex items-center justify-between p-3 rounded-lg border hover:bg-muted/50 transition-colors">
									<div class="flex items-center gap-3">
										<div class="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
											<FolderOpen class="h-4 w-4" />
										</div>
										<div>
											<h3 class="font-medium">{child.name}</h3>
										</div>
									</div>
									<Button href="/dashboard/inventory/containers/{child.id}" variant="ghost" size="sm">
										View
									</Button>
								</div>
							{/each}
						</div>
					</CardContent>
				</Card>
			{/if}

			<!-- Items -->
			<Card>
				<CardHeader>
					<CardTitle class="flex items-center justify-between">
						<span class="flex items-center gap-2">
							<Package class="h-5 w-5" />
							Items ({container.items?.length || 0})
						</span>
						{#if data.canEdit}
							<Button href="/dashboard/inventory/items/create?container={container.id}" size="sm">
								<Plus class="mr-2 h-4 w-4" />
								Add Item
							</Button>
						{/if}
					</CardTitle>
				</CardHeader>
				<CardContent>
					{#if !container.items || container.items.length === 0 && data.canEdit}
						<div class="text-center py-8">
							<Package class="h-12 w-12 text-muted-foreground mx-auto mb-4" />
							<h3 class="text-lg font-semibold mb-2">No items yet</h3>
							<p class="text-muted-foreground mb-4">Add items to this container to start tracking your inventory</p>
							<Button href="/dashboard/inventory/items/create?container={container.id}">
								<Plus class="mr-2 h-4 w-4" />
								Add First Item
							</Button>
						</div>
					{:else}
						<div class="space-y-2">
							{#each container.items as item}
								<div
									class="flex items-center justify-between p-3 rounded-lg border hover:bg-muted/50 transition-colors">
									<div class="flex items-center gap-3">
										<div class="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
											<Package class="h-4 w-4" />
										</div>
										<div>
											<h3 class="font-medium">{getItemDisplayName(item)}</h3>
											<div class="flex items-center gap-2 mt-1">
												<Badge variant="secondary" class="text-xs">
													{item.category?.name || 'Uncategorized'}
												</Badge>
												<Badge variant="outline" class="text-xs">
													Qty: {item.quantity}
												</Badge>
												{#if item.out_for_maintenance}
													<Badge variant="destructive" class="text-xs flex items-center gap-1">
														<AlertTriangle class="h-3 w-3" />
														Maintenance
													</Badge>
												{/if}
											</div>
										</div>
									</div>
									<Button href="/dashboard/inventory/items/{item.id}" variant="ghost" size="sm">
										View
									</Button>
								</div>
							{/each}
						</div>
					{/if}
				</CardContent>
			</Card>
		</div>
	</div>
</div>
