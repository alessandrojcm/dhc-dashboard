<script lang="ts">
	import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import { 
		ArrowLeft, 
		Package, 
		Edit,
		AlertTriangle,
		FolderOpen,
		Tags,
		Clock,
		User,
		Plus
	} from 'lucide-svelte';
	import dayjs from 'dayjs';
	import relativeTime from 'dayjs/plugin/relativeTime';

	dayjs.extend(relativeTime);

	let { data } = $props();
	const { item, history } = data;

	const getItemDisplayName = (item: any) => {
		if (item.attributes?.name) return item.attributes.name;
		if (item.attributes?.brand && item.attributes?.type) {
			return `${item.attributes.brand} ${item.attributes.type}`;
		}
		return `${item.category?.name || 'Item'} #${item.id.slice(-8)}`;
	};

	const getActionIcon = (action: string) => {
		switch (action) {
			case 'created': return Plus;
			case 'moved': return Package;
			case 'updated': return Clock;
			default: return Clock;
		}
	};

	const getActionColor = (action: string) => {
		switch (action) {
			case 'created': return 'text-green-600';
			case 'moved': return 'text-blue-600';
			case 'updated': return 'text-yellow-600';
			default: return 'text-gray-600';
		}
	};
</script>

<div class="p-6">
	<div class="mb-6">
		<div class="flex items-center gap-2 mb-2">
			<Button href="/dashboard/inventory/items" variant="ghost" size="sm">
				<ArrowLeft class="h-4 w-4" />
			</Button>
			<h1 class="text-3xl font-bold">{getItemDisplayName(item)}</h1>
			{#if item.out_for_maintenance}
				<Badge variant="destructive" class="flex items-center gap-1">
					<AlertTriangle class="h-3 w-3" />
					Out for Maintenance
				</Badge>
			{/if}
		</div>
		<p class="text-muted-foreground">Item details and history</p>
	</div>

	<div class="grid gap-6 lg:grid-cols-3">
		<!-- Item Information -->
		<div class="lg:col-span-2 space-y-6">
			<Card>
				<CardHeader>
					<CardTitle class="flex items-center gap-2">
						<Package class="h-5 w-5" />
						Item Information
					</CardTitle>
				</CardHeader>
				<CardContent class="space-y-4">
					<div class="grid gap-4 md:grid-cols-2">
						<div>
							<h3 class="font-medium">Category</h3>
							<div class="flex items-center gap-2 mt-1">
								<Tags class="h-4 w-4 text-muted-foreground" />
								<span class="text-sm">{item.category?.name || 'Uncategorized'}</span>
							</div>
						</div>

						<div>
							<h3 class="font-medium">Container</h3>
							<div class="flex items-center gap-2 mt-1">
								<FolderOpen class="h-4 w-4 text-muted-foreground" />
								<Button 
									href="/dashboard/inventory/containers/{item.container.id}" 
									variant="link" 
									class="p-0 h-auto text-sm"
								>
									{item.container.name}
								</Button>
							</div>
						</div>

						<div>
							<h3 class="font-medium">Quantity</h3>
							<p class="text-sm text-muted-foreground mt-1">{item.quantity}</p>
						</div>

						<div>
							<h3 class="font-medium">Status</h3>
							<div class="mt-1">
								{#if item.out_for_maintenance}
									<Badge variant="destructive" class="text-xs">Out for Maintenance</Badge>
								{:else}
									<Badge variant="secondary" class="text-xs">Available</Badge>
								{/if}
							</div>
						</div>
					</div>

					{#if item.notes}
						<div>
							<h3 class="font-medium">Notes</h3>
							<p class="text-sm text-muted-foreground mt-1">{item.notes}</p>
						</div>
					{/if}

					<div class="grid gap-4 md:grid-cols-2">
						<div>
							<h3 class="font-medium">Created</h3>
							<p class="text-sm text-muted-foreground mt-1">
								{dayjs(item.created_at).format('MMM D, YYYY [at] h:mm A')}
							</p>
						</div>

						<div>
							<h3 class="font-medium">Last Updated</h3>
							<p class="text-sm text-muted-foreground mt-1">
								{dayjs(item.updated_at).format('MMM D, YYYY [at] h:mm A')}
							</p>
						</div>
					</div>
				</CardContent>
			</Card>

			<!-- Attributes -->
			{#if item.category?.available_attributes && Object.keys(item.category.available_attributes).length > 0}
				<Card>
					<CardHeader>
						<CardTitle>Attributes</CardTitle>
						<CardDescription>Category-specific attributes for this item</CardDescription>
					</CardHeader>
					<CardContent>
						<div class="grid gap-4 md:grid-cols-2">
							{#each Object.entries(item.category.available_attributes) as [key, attrDef]}
								<div>
									<h3 class="font-medium">{attrDef.label || key}</h3>
									<p class="text-sm text-muted-foreground mt-1">
										{#if item.attributes[key] !== undefined && item.attributes[key] !== null}
											{#if attrDef.type === 'boolean'}
												{item.attributes[key] ? 'Yes' : 'No'}
											{:else}
												{item.attributes[key]}
											{/if}
										{:else}
											<span class="italic">Not set</span>
										{/if}
									</p>
								</div>
							{/each}
						</div>
					</CardContent>
				</Card>
			{/if}
		</div>

		<!-- Actions & History -->
		<div class="space-y-6">
			<!-- Actions -->
			<Card>
				<CardHeader>
					<CardTitle>Actions</CardTitle>
				</CardHeader>
				<CardContent class="space-y-3">
					<Button href="/dashboard/inventory/items/{item.id}/edit" class="w-full">
						<Edit class="mr-2 h-4 w-4" />
						Edit Item
					</Button>
					<Button href="/dashboard/inventory/containers/{item.container.id}" variant="outline" class="w-full">
						<FolderOpen class="mr-2 h-4 w-4" />
						View Container
					</Button>
				</CardContent>
			</Card>

			<!-- History -->
			<Card>
				<CardHeader>
					<CardTitle class="flex items-center gap-2">
						<Clock class="h-5 w-5" />
						History
					</CardTitle>
					<CardDescription>Recent changes to this item</CardDescription>
				</CardHeader>
				<CardContent>
					{#if history.length === 0}
						<p class="text-sm text-muted-foreground">No history available</p>
					{:else}
						<div class="space-y-3">
							{#each history as entry}
								<div class="flex items-start gap-3">
									<div class="flex h-8 w-8 items-center justify-center rounded-full bg-muted">
										<svelte:component this={getActionIcon(entry.action)} class="h-4 w-4 {getActionColor(entry.action)}" />
									</div>
									<div class="flex-1 space-y-1">
										<p class="text-sm">
											<span class="font-medium capitalize">{entry.action}</span>
											{#if entry.action === 'moved' && entry.old_container && entry.new_container}
												from {entry.old_container.name} to {entry.new_container.name}
											{/if}
										</p>
										<p class="text-xs text-muted-foreground">
											{dayjs(entry.created_at).fromNow()}
										</p>
									</div>
								</div>
							{/each}
						</div>
					{/if}
				</CardContent>
			</Card>
		</div>
	</div>
</div>