<script lang="ts">
	import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import { Tags, Plus, Edit, Package } from 'lucide-svelte';

	let { data } = $props();

	const getAttributeCount = (category: any) => {
		return Object.keys(category.available_attributes || {}).length;
	};

	const getItemCount = (category: any) => {
		return category.item_count?.[0]?.count || 0;
	};
</script>

<div class="p-6">
	<div class="flex items-center justify-between mb-6">
		<div>
			<h1 class="text-3xl font-bold">Equipment Categories</h1>
			<p class="text-muted-foreground">Manage equipment types and their attributes</p>
		</div>
		<Button href="/dashboard/inventory/categories/create">
			<Plus class="mr-2 h-4 w-4" />
			Add Category
		</Button>
	</div>

	{#if data.categories.length === 0}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<Tags class="h-12 w-12 text-muted-foreground mb-4" />
				<h3 class="text-lg font-semibold mb-2">No categories yet</h3>
				<p class="text-muted-foreground mb-4">
					Create your first equipment category to start organizing your inventory
				</p>
				<Button href="/dashboard/inventory/categories/create">
					<Plus class="mr-2 h-4 w-4" />
					Create Category
				</Button>
			</CardContent>
		</Card>
	{:else}
		<div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
			{#each data.categories as category}
				<Card class="hover:shadow-md transition-shadow">
					<CardHeader>
						<CardTitle class="flex items-center justify-between">
							<span class="flex items-center gap-2">
								<Tags class="h-5 w-5" />
								{category.name}
							</span>
							<Button
								href="/dashboard/inventory/categories/{category.id}/edit"
								variant="ghost"
								size="sm"
							>
								<Edit class="h-4 w-4" />
							</Button>
						</CardTitle>
					</CardHeader>
					<CardContent>
						{#if category.description}
							<p class="text-sm text-muted-foreground mb-4">{category.description}</p>
						{/if}

						<div class="flex items-center gap-4 mb-4">
							<div class="flex items-center gap-1">
								<Badge variant="secondary" class="text-xs">
									{getAttributeCount(category)} attribute{getAttributeCount(category) !== 1
										? 's'
										: ''}
								</Badge>
							</div>
							<div class="flex items-center gap-1">
								<Badge variant="outline" class="text-xs flex items-center gap-1">
									<Package class="h-3 w-3" />
									{getItemCount(category)} item{getItemCount(category) !== 1 ? 's' : ''}
								</Badge>
							</div>
						</div>

						{#if getAttributeCount(category) > 0}
							<div class="space-y-2">
								<h4 class="text-sm font-medium">Attributes:</h4>
								<div class="flex flex-wrap gap-1">
									{#each Object.entries(category.available_attributes || {}) as [key, attr]}
										<Badge variant="outline" class="text-xs">
											{attr.label || key}
											{#if attr.required}
												<span class="text-destructive">*</span>
											{/if}
										</Badge>
									{/each}
								</div>
							</div>
						{/if}

						<div class="flex gap-2 mt-4">
							<Button
								href="/dashboard/inventory/items?category={category.id}"
								variant="outline"
								size="sm"
								class="flex-1"
							>
								View Items
							</Button>
							<Button
								href="/dashboard/inventory/categories/{category.id}/edit"
								variant="outline"
								size="sm"
							>
								Edit
							</Button>
						</div>
					</CardContent>
				</Card>
			{/each}
		</div>
	{/if}
</div>
