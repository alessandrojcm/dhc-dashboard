<script lang="ts">
	import type { ComponentProps } from 'svelte';
	import * as Sidebar from '$lib/components/ui/sidebar/index.js';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import * as Avatar from '$lib/components/ui/avatar';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import { Button } from '$lib/components/ui/button';
	import type { NavData, UserData } from '$lib/types';
	import DHCLogo from '/src/assets/images/dhc-logo.png?enhanced';
	import NotificationCenter from '$lib/components/notifications/NotificationCenter.svelte';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import { Menu } from 'lucide-svelte';
	import { useSidebar } from '$lib/components/ui/sidebar/context.svelte.js';

	type Props = {
		className?: string | undefined | null;
		logout: () => void;
		userData: Promise<Partial<UserData>>;
		roles: Set<string>;
		navData: NavData;
		supabase: SupabaseClient;
	};

	// Get the sidebar context
	const sidebar = useSidebar();

	// Function to toggle the sidebar on mobile
	function toggleSidebar() {
		sidebar.toggle();
		console.log('Sidebar toggled on mobile');
	}

	let {
		ref = $bindable(null),
		collapsible = 'offcanvas',
		userData,
		logout,
		roles,
		navData: data,
		supabase,
		...restProps
	}: ComponentProps<typeof Sidebar.Root> & Props = $props();
</script>

<div class="md:hidden fixed top-4 left-4 z-50">
	<Button 
		variant="outline" 
		size="icon" 
		aria-label="Toggle menu"
		onclick={toggleSidebar}
	>
		<Menu class="h-4 w-4" />
	</Button>
</div>

<Sidebar.Root 
	bind:ref 
	{collapsible} 
	{...restProps} 
	class="h-[100vh] border-r-1 md:block">

	<Sidebar.Header class="flex flex-row items-center">
		<div class="h-12 w-12">
			<enhanced:img src={DHCLogo} alt="Dublin Hema Club Logo" />
		</div>
		<h2 class="text-lg mt-2 text-black font-medium">Dublin Hema Club</h2>
	</Sidebar.Header>
	<Sidebar.Content data-testid="sidebar">
		<!-- We create a Sidebar.Group for each parent. -->
		{#each data.navMain as group (group.title)}
			{#if group.role.intersection(roles).size > 0}
				<Sidebar.Group>
					{#if group?.items}
						<Sidebar.GroupLabel>{group.title}</Sidebar.GroupLabel>
						<Sidebar.GroupContent>
							<Sidebar.Menu>
								{#each group.items as item (item.title)}
									{#if item.role.intersection(roles).size > 0}
										<Sidebar.MenuItem>
											<Sidebar.MenuButton
												class="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
											>
												<a href={`/dashboard/${item.url}`}>{item.title}</a>
											</Sidebar.MenuButton>
										</Sidebar.MenuItem>
									{/if}
								{/each}
							</Sidebar.Menu>
						</Sidebar.GroupContent>
					{:else}
						<Sidebar.MenuButton
							class="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
						>
							<a href={`/dashboard/${group.url}`}>{group.title}</a>
						</Sidebar.MenuButton>
					{/if}
				</Sidebar.Group>
			{/if}
		{/each}
	</Sidebar.Content>
	<Sidebar.Footer class="m-2 mb-4">
		<Sidebar.Menu>
			<!-- Notifications Item -->
			<Sidebar.MenuItem>
				<NotificationCenter {supabase} />
			</Sidebar.MenuItem>

			<!-- User Profile Item -->
			<Sidebar.MenuItem>
				<DropdownMenu.Root>
					{#await userData}
						<Skeleton class="h-[50px]" />
					{:then user}
						<DropdownMenu.Trigger>
							<Sidebar.MenuButton
								size="lg"
								class="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
							>
								<Avatar.Root class="h-8 w-8">
									<Avatar.Fallback
									>{user?.firstName?.charAt(0)}{user?.lastName?.charAt(0)}</Avatar.Fallback
									>
								</Avatar.Root>
								<div class="flex flex-col space-y-1">
									<p class="text-sm font-medium leading-none">{user?.firstName} {user?.lastName}</p>
									<p class="text-muted-foreground text-xs leading-none">{user?.email}</p>
								</div>
							</Sidebar.MenuButton>
						</DropdownMenu.Trigger>
						<DropdownMenu.Content class="w-56" align="end">
							{#if roles.size > 1}
								<DropdownMenu.Item>
									<a href={`/dashboard/members/${user?.id}`}>My Profile</a>
								</DropdownMenu.Item>
							{/if}
							<DropdownMenu.Item onclick={logout}>Log out</DropdownMenu.Item>
						</DropdownMenu.Content>
					{/await}
				</DropdownMenu.Root>
			</Sidebar.MenuItem>
		</Sidebar.Menu>
	</Sidebar.Footer>
</Sidebar.Root>
