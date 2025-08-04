<script lang="ts">
	import { page } from '$app/state';
	import { Button } from '$lib/components/ui/button';
	import type { LayoutProps } from './$types';
	import {
		Package,
		FolderOpen,
		Tags,
		Search,
		Plus
	} from 'lucide-svelte';

	let { children, data }: LayoutProps = $props();
	const canEdit = data.canEdit;

	const navItems = [
		{ href: '/dashboard/inventory', label: 'Overview', icon: Package },
		{ href: '/dashboard/inventory/containers', label: 'Containers', icon: FolderOpen },
		{ href: '/dashboard/inventory/categories', label: 'Categories', icon: Tags },
		{ href: '/dashboard/inventory/items', label: 'Items', icon: Search }
	];

	const isActive = (href: string) => {
		if (href === '/dashboard/inventory') {
			return page.url.pathname === href;
		}
		return page.url.pathname.startsWith(href);
	};
</script>

<div class="flex h-full">
	<!-- Sidebar Navigation -->
	<div class="w-64 border-r bg-muted/10 p-4">
		<div class="mb-6">
			<h2 class="text-lg font-semibold">Inventory Management</h2>
			<p class="text-sm text-muted-foreground">Manage containers, categories, and items</p>
		</div>

		<nav class="space-y-2">
			{#each navItems as item}
				<a
					href={item.href}
					class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors hover:bg-accent hover:text-accent-foreground {isActive(item.href) ? 'bg-accent text-accent-foreground' : 'text-muted-foreground'}"
				>
					<svelte:component this={item.icon} class="h-4 w-4" />
					{item.label}
				</a>
			{/each}
		</nav>

		<!-- Quick Actions -->
		{#if canEdit}
			<div class="mt-8 space-y-2">
				<h3 class="text-sm font-medium text-muted-foreground">Quick Actions</h3>
				<Button href="/dashboard/inventory/containers/create" variant="outline" size="sm" class="w-full justify-start">
					<Plus class="mr-2 h-4 w-4" />
					Add Container
				</Button>
				<Button href="/dashboard/inventory/categories/create" variant="outline" size="sm" class="w-full justify-start">
					<Plus class="mr-2 h-4 w-4" />
					Add Category
				</Button>
				<Button href="/dashboard/inventory/items/create" variant="outline" size="sm" class="w-full justify-start">
					<Plus class="mr-2 h-4 w-4" />
					Add Item
				</Button>
			</div>
		{/if}
	</div>

	<!-- Main Content -->
	<div class="flex-1 overflow-auto">
		{@render children()}
	</div>
</div>
