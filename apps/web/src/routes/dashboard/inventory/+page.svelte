<script lang="ts">
import { Boxes, FolderTree } from "@lucide/svelte";
</script>

<svelte:head><title>Inventory structure | Dublin HEMA Club</title></svelte:head>

<div class="mx-auto max-w-5xl space-y-6 px-4 py-8 sm:px-6">
	<header>
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Operator inventory
		</p>
		<h1 class="font-heading text-3xl font-bold">Structure</h1>
		<p class="mt-2 max-w-2xl text-sm text-muted-foreground">
			Manage the taxonomy and physical storage hierarchy used by every inventory
			item.
		</p>
	</header>
	<div class="grid gap-4 sm:grid-cols-2">
		<a
			href="/dashboard/inventory/categories"
			class="rounded-2xl border bg-card p-6 shadow-sm transition-colors hover:bg-muted/40 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
		>
			<Boxes class="mb-4 size-8 text-primary" aria-hidden="true" />
			<h2 class="text-xl font-semibold">Categories and properties</h2>
			<p class="mt-2 text-sm text-muted-foreground">
				Create categories, typed definitions, and single-select options.
			</p>
		</a>
		<a
			href="/dashboard/inventory/containers"
			class="rounded-2xl border bg-card p-6 shadow-sm transition-colors hover:bg-muted/40 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
		>
			<FolderTree class="mb-4 size-8 text-primary" aria-hidden="true" />
			<h2 class="text-xl font-semibold">Containers</h2>
			<p class="mt-2 text-sm text-muted-foreground">
				Arrange storage locations without cycles or hidden cascades.
			</p>
		</a>
	</div>
</div>
