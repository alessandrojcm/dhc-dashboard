<script lang="ts">
	import type { ComponentProps } from "svelte";
	import * as Sidebar from "$lib/components/ui/sidebar/index.js";
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import * as Avatar from '$lib/components/ui/avatar';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import type { NavData, UserData } from '$lib/types';

	const data: NavData = {
		navMain: [
			{
				title: "Beginners Workshop",
				url: "beginners-workshop",
				role: new Set(['admin', 'coach', 'beginners_coordinator', 'president']),
				items: [
					{
						title: "Waitlist",
						url: 'beginners-workshop/waitlist',
						role: new Set(['admin', 'coach', 'beginners_coordinator', 'president']),
					}
				],
			},
		],
	};

	type Props = {
		className?: string | undefined | null;
		logout: () => void;
		userData: Promise<UserData>;
		roles: Set<string>;
	};

	let {
		ref = $bindable(null),
		collapsible = "none",
		userData,
		logout,
		roles,
		...restProps
	}: ComponentProps<typeof Sidebar.Root> & Props = $props();
</script>

<Sidebar.Root bind:ref {collapsible} {...restProps} class="h-[100vh]">
	<Sidebar.Header>
		<h2 class="text-lg mt-2 text-black font-medium">Dublin Hema Club</h2>
	</Sidebar.Header>
	<Sidebar.Content>
		<!-- We create a Sidebar.Group for each parent. -->
		{#each data.navMain as group (group.title)}
			{#if group.role.intersection(roles).size > 0}
				<Sidebar.Group>
					<Sidebar.GroupLabel>{group.title}</Sidebar.GroupLabel>
					<Sidebar.GroupContent>
						<Sidebar.Menu>
							{#each group.items as item (item.title)}
								{#if item.role.intersection(roles).size > 0}
									<Sidebar.MenuItem>
										<Sidebar.MenuButton
											class="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
										>
											{item.title}
										</Sidebar.MenuButton>
									</Sidebar.MenuItem>
								{/if}
							{/each}
						</Sidebar.Menu>
					</Sidebar.GroupContent>
				</Sidebar.Group>
			{/if}
		{/each}
	</Sidebar.Content>
	<Sidebar.Footer class="m-2 mb-4">
		<Sidebar.Menu>
			<Sidebar.MenuItem>
				<DropdownMenu.Root>
					<DropdownMenu.Trigger>
						<Sidebar.MenuButton
							size="lg"
							class="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
						>
							{#await userData}
								<Skeleton class="h-[50px]" />
							{:then user}
								<Avatar.Root class="h-8 w-8">
									<Avatar.Fallback>{user.firstName.charAt(0)}{user.lastName.charAt(0)}</Avatar.Fallback>
								</Avatar.Root>

								<div class="flex flex-col space-y-1">
									<p class="text-sm font-medium leading-none">{user.firstName} {user.lastName}</p>
									<p class="text-muted-foreground text-xs leading-none">{user.email}</p>
								</div>
							{/await}
						</Sidebar.MenuButton>
					</DropdownMenu.Trigger>
					<DropdownMenu.Content class="w-56" align="end">
						<DropdownMenu.Item onclick={logout}>Log out</DropdownMenu.Item>
					</DropdownMenu.Content>
				</DropdownMenu.Root>
			</Sidebar.MenuItem>
		</Sidebar.Menu>
	</Sidebar.Footer>
</Sidebar.Root>
