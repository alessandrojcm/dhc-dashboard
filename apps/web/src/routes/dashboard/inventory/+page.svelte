<script lang="ts">
import { ClipboardList, FolderTree, PackageSearch, Tags } from "@lucide/svelte";
import InventoryPageHeader from "$lib/components/inventory/InventoryPageHeader.svelte";
</script>

<svelte:head><title>Inventory structure | Dublin HEMA Club</title></svelte:head>

<div class="inventory-page">
	<InventoryPageHeader
		eyebrow="Quartermaster"
		title="Inventory workspace"
		description="Start with the loan queue, or open the pages that track club gear and where it's stored."
		icon={PackageSearch}
	/>
	<div class="grid gap-4 sm:grid-cols-2">
		<a
			href="/dashboard/inventory/loans"
			class="inventory-card group p-6 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
		>
			<ClipboardList class="mb-4 size-8 text-primary" aria-hidden="true" />
			<h2 class="text-xl font-semibold">Loan queue</h2>
			<p class="mt-2 text-sm text-muted-foreground">
				Review requests and record handovers and returns from the shared queue.
			</p>
		</a>
		<a
			href="/dashboard/inventory/items"
			class="inventory-card group p-6 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
		>
			<PackageSearch class="mb-4 size-8 text-primary" aria-hidden="true" />
			<h2 class="text-xl font-semibold">Items</h2>
			<p class="mt-2 text-sm text-muted-foreground">
				Create, find, move, maintain, archive, and restore items.
			</p>
		</a>
		<a
			href="/dashboard/inventory/categories"
			class="inventory-card group p-6 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
		>
			<Tags class="mb-4 size-8 text-primary" aria-hidden="true" />
			<h2 class="text-xl font-semibold">Categories and properties</h2>
			<p class="mt-2 text-sm text-muted-foreground">
				Create categories, typed definitions, and single-select options.
			</p>
		</a>
		<a
			href="/dashboard/inventory/containers"
			class="inventory-card group p-6 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
		>
			<FolderTree class="mb-4 size-8 text-primary" aria-hidden="true" />
			<h2 class="text-xl font-semibold">Containers</h2>
			<p class="mt-2 text-sm text-muted-foreground">
				Arrange storage locations without cycles or hidden cascades.
			</p>
		</a>
	</div>
</div>
