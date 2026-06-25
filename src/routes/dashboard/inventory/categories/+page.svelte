<script lang="ts">
import { inventoryCategoriesOptions } from "@dhc/api-client";
import type { InventoryCategory } from "@dhc/api-client";
import { createQuery } from "@tanstack/svelte-query";
import {
	Card,
	CardContent,
	CardHeader,
	CardTitle,
} from "$lib/components/ui/card";
import { Button } from "$lib/components/ui/button";
import { Badge } from "$lib/components/ui/badge";
import { Tags, Plus, Edit, Package, AlertTriangle } from "lucide-svelte";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";

// Equipment Categories come from Phoenix (`GET /api/inventory/categories`,
// issue ALE-96) via the generated TanStack Query options. The Supabase JWT is
// attached by `configureClient`'s `getAuthToken` hook; authz is enforced by
// Phoenix's `inventory_admin_api` pipeline, so no redundant SvelteKit
// `authorize()` gate is needed for the read (the layout's
// `authorize(INVENTORY_ROLES)` still gates page access). Replaces the
// client-side Supabase/PostgREST read over `equipment_categories` (with an
// `equipment_items(count)` aggregate).
const categoriesQuery = createQuery(() => inventoryCategoriesOptions());

const categories = $derived(categoriesQuery.data?.data.categories ?? []);

const getAttributeCount = (category: InventoryCategory) => {
	return category.availableAttributes.length;
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

	{#if categoriesQuery.isPending}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<LoaderCircle />
				<p class="text-muted-foreground mt-4">Loading categories...</p>
			</CardContent>
		</Card>
	{:else if categoriesQuery.isError}
		<Card>
			<CardContent class="flex flex-col items-center justify-center py-12">
				<AlertTriangle class="h-12 w-12 text-destructive mb-4" />
				<h3 class="text-lg font-semibold mb-2">Error loading categories</h3>
				<p class="text-muted-foreground mb-4">{categoriesQuery.error.message}</p>
				<Button onclick={() => categoriesQuery.refetch()} variant="outline">Retry</Button>
			</CardContent>
		</Card>
	{:else if categories.length === 0}
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
			{#each categories as category (category.id)}
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
									{category.itemCount} item{category.itemCount !== 1 ? 's' : ''}
								</Badge>
							</div>
						</div>

						{#if getAttributeCount(category) > 0}
							<div class="space-y-2">
								<h4 class="text-sm font-medium">Attributes:</h4>
								<div class="flex flex-wrap gap-1">
									{#each category.availableAttributes as attr, i (i)}
										<Badge variant="outline" class="text-xs">
											{attr.label || attr.name}
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