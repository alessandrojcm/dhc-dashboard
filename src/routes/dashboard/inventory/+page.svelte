<script lang="ts">
	import {
		Card,
		CardContent,
		CardDescription,
		CardHeader,
		CardTitle
	} from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Package, FolderOpen, Tags, AlertTriangle, Plus, Clock } from 'lucide-svelte';
	import dayjs from 'dayjs';
	import relativeTime from 'dayjs/plugin/relativeTime';

	dayjs.extend(relativeTime);

	let { data } = $props();

	const getActionIcon = (action: string) => {
		switch (action) {
			case 'created':
				return Plus;
			case 'moved':
				return Package;
			case 'updated':
				return Clock;
			default:
				return Clock;
		}
	};

	const getActionColor = (action: string) => {
		switch (action) {
			case 'created':
				return 'text-green-600';
			case 'moved':
				return 'text-blue-600';
			case 'updated':
				return 'text-yellow-600';
			default:
				return 'text-gray-600';
		}
	};
</script>

<div class="p-6">
	<div class="mb-6">
		<h1 class="text-3xl font-bold">Inventory Overview</h1>
		<p class="text-muted-foreground">Manage your equipment, containers, and categories</p>
	</div>

	<!-- Stats Cards -->
	<div class="grid gap-4 md:grid-cols-2 lg:grid-cols-4 mb-8">
		<Card>
			<CardHeader class="flex flex-row items-center justify-between space-y-0 pb-2">
				<CardTitle class="text-sm font-medium">Total Containers</CardTitle>
				<FolderOpen class="h-4 w-4 text-muted-foreground" />
			</CardHeader>
			<CardContent>
				<div class="text-2xl font-bold">{data.stats.containers}</div>
				<p class="text-xs text-muted-foreground">Storage locations</p>
			</CardContent>
		</Card>

		<Card>
			<CardHeader class="flex flex-row items-center justify-between space-y-0 pb-2">
				<CardTitle class="text-sm font-medium">Categories</CardTitle>
				<Tags class="h-4 w-4 text-muted-foreground" />
			</CardHeader>
			<CardContent>
				<div class="text-2xl font-bold">{data.stats.categories}</div>
				<p class="text-xs text-muted-foreground">Equipment types</p>
			</CardContent>
		</Card>

		<Card>
			<CardHeader class="flex flex-row items-center justify-between space-y-0 pb-2">
				<CardTitle class="text-sm font-medium">Total Items</CardTitle>
				<Package class="h-4 w-4 text-muted-foreground" />
			</CardHeader>
			<CardContent>
				<div class="text-2xl font-bold">{data.stats.items}</div>
				<p class="text-xs text-muted-foreground">Equipment pieces</p>
			</CardContent>
		</Card>

		<Card>
			<CardHeader class="flex flex-row items-center justify-between space-y-0 pb-2">
				<CardTitle class="text-sm font-medium">Maintenance</CardTitle>
				<AlertTriangle class="h-4 w-4 text-muted-foreground" />
			</CardHeader>
			<CardContent>
				<div class="text-2xl font-bold text-orange-600">{data.stats.maintenance}</div>
				<p class="text-xs text-muted-foreground">Items out for maintenance</p>
			</CardContent>
		</Card>
	</div>

	<div class="grid gap-6 md:grid-cols-2">
		<!-- Quick Actions -->
		<Card>
			<CardHeader>
				<CardTitle>Quick Actions</CardTitle>
				<CardDescription>Common inventory management tasks</CardDescription>
			</CardHeader>
			<CardContent class="space-y-3">
				<Button href="/dashboard/inventory/containers/create" class="w-full justify-start">
					<FolderOpen class="mr-2 h-4 w-4" />
					Create New Container
				</Button>
				<Button
					href="/dashboard/inventory/categories/create"
					variant="outline"
					class="w-full justify-start"
				>
					<Tags class="mr-2 h-4 w-4" />
					Add Equipment Category
				</Button>
				<Button
					href="/dashboard/inventory/items/create"
					variant="outline"
					class="w-full justify-start"
				>
					<Package class="mr-2 h-4 w-4" />
					Add New Item
				</Button>
			</CardContent>
		</Card>

		<!-- Recent Activity -->
		<Card>
			<CardHeader>
				<CardTitle>Recent Activity</CardTitle>
				<CardDescription>Latest inventory changes</CardDescription>
			</CardHeader>
			<CardContent>
				{#if data.recentActivity.length === 0}
					<p class="text-sm text-muted-foreground">No recent activity</p>
				{:else}
					<div class="space-y-3">
						{#each data.recentActivity.slice(0, 5) as activity (activity.id)}
							{@const ActionIcon = getActionIcon(activity.action)}
							<div class="flex items-start gap-3">
								<div class="flex h-8 w-8 items-center justify-center rounded-full bg-muted">
									<ActionIcon class="h-4 w-4 {getActionColor(activity.action)}" />
								</div>
								<div class="flex-1 space-y-1">
									<p class="text-sm">
										<span class="font-medium capitalize">{activity.action}</span>
										{#if activity.item?.attributes?.name}
											item "{activity.item.attributes.name}"
										{:else}
											item
										{/if}
										{#if activity.action === 'moved' && activity.old_container && activity.new_container}
											from {activity.old_container.name} to {activity.new_container.name}
										{/if}
									</p>
									<p class="text-xs text-muted-foreground">
										{dayjs(activity.created_at).fromNow()}
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
