<script lang="ts">
import type { ComponentProps } from "svelte";
import * as Sidebar from "$lib/components/ui/sidebar/index.js";
import * as DropdownMenu from "$lib/components/ui/dropdown-menu";
import * as Avatar from "$lib/components/ui/avatar";
import { Skeleton } from "$lib/components/ui/skeleton";
import { Button } from "$lib/components/ui/button";
import type { NavData, UserData } from "$lib/types";
import DHCLogo from "/src/assets/images/dhc-logo.png?enhanced";
import NotificationCenter from "$lib/components/notifications/NotificationCenter.svelte";
import { Menu, Shield } from "@lucide/svelte";
import { useSidebar } from "$lib/components/ui/sidebar/context.svelte.js";
import { browser } from "$app/environment";
import { resolve } from "$app/paths";
import type { Pathname } from "$app/types";

type Props = {
	className?: string | undefined | null;
	logout: () => void;
	userData: Promise<Partial<UserData>>;
	roles: Set<string>;
	navData: NavData;
};

// Get the sidebar context
const sidebar = useSidebar();

// Function to toggle the sidebar on mobile
function toggleSidebar() {
	if (!browser) return;
	// We only want to toggle the sidebar on mobile
	if (window.innerWidth < 768) {
		sidebar.toggle();
	}
}

function resolvePath(path: Pathname) {
	// `Pathname` is already constrained to valid application paths. SvelteKit's
	// overload cannot represent the full generated union as a single argument.
	return resolve(path as "/");
}

let {
	ref = $bindable(null),
	collapsible = "offcanvas",
	userData,
	logout,
	roles,
	navData: data,
	...restProps
}: ComponentProps<typeof Sidebar.Root> & Props = $props();
let customAnchor = $state<HTMLElement>(null!);
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
	class="h-dvh border-r md:block shadow-xl shadow-primary/10"
>
	<Sidebar.Header class="brand-header">
		<div class="brand-mark">
			<enhanced:img src={DHCLogo} alt="Dublin Hema Club Logo" />
		</div>
		<div>
			<p class="brand-kicker">Established in Dublin</p>
			<h2>Dublin Hema Club</h2>
		</div>
	</Sidebar.Header>
	<Sidebar.Content data-testid="sidebar">
		<!-- We create a Sidebar.Group for each parent. -->
		{#each data.navMain as group (group.title)}
			{#if group.role.intersection(roles).size > 0}
				<Sidebar.Group>
					{#if group?.items}
						<Sidebar.GroupLabel class="nav-group-label"
							>{group.title}</Sidebar.GroupLabel
						>
						<Sidebar.GroupContent>
							<Sidebar.Menu>
								{#each group.items as item (item.title)}
									{#if item.role.intersection(roles).size > 0}
										<Sidebar.MenuItem>
											<Sidebar.MenuButton
												onclick={toggleSidebar}
												class="nav-item data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
											>
												<a href={resolvePath(item.url)}>{item.title}</a>
											</Sidebar.MenuButton>
										</Sidebar.MenuItem>
									{/if}
								{/each}
							</Sidebar.Menu>
						</Sidebar.GroupContent>
					{:else}
						<Sidebar.MenuButton
							onclick={toggleSidebar}
							class="nav-item data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
						>
							<a href={resolvePath(group.url)}>{group.title}</a>
						</Sidebar.MenuButton>
					{/if}
				</Sidebar.Group>
			{/if}
		{/each}
	</Sidebar.Content>
	<Sidebar.Footer class="m-2 mb-4">
		<div class="member-note">
			<Shield size={15} aria-hidden="true" />
			<span>Member workspace</span>
		</div>
		<Sidebar.Menu>
			<!-- Notifications Item -->
			<Sidebar.MenuItem>
				<NotificationCenter />
			</Sidebar.MenuItem>

			<!-- User Profile Item -->
			<Sidebar.MenuItem>
				<div bind:this={customAnchor}></div>
				<DropdownMenu.Root>
					{#await userData}
						<Skeleton class="h-[50px]" />
					{:then user}
						<DropdownMenu.Trigger>
							<Sidebar.MenuButton
								size="lg"
								class="data-[state=open]:bg-sidebar-accent cursor-pointer data-[state=open]:text-sidebar-accent-foreground"
							>
								<Avatar.Root class="h-8 w-8">
									<Avatar.Fallback
										>{user?.firstName?.charAt(0)}{user?.lastName?.charAt(
											0,
										)}</Avatar.Fallback
									>
								</Avatar.Root>
								<div class="flex flex-col space-y-1">
									<p class="text-sm font-medium leading-none">
										{user?.firstName}
										{user?.lastName}
									</p>
									<p class="text-muted-foreground text-xs leading-none">
										{user?.email}
									</p>
								</div>
							</Sidebar.MenuButton>
						</DropdownMenu.Trigger>

						<DropdownMenu.Content strategy="fixed" {customAnchor} class="w-56">
							{#if roles.size > 1}
								<DropdownMenu.Item>
									<a href={resolve(`/dashboard/members/${user?.id}`)}
										>My Profile</a
									>
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

<style>
.brand-header {
	display: flex;
	align-items: center;
	gap: 0.75rem;
	padding: 1.25rem 1rem 1rem;
}

.brand-mark {
	display: grid;
	height: 2.75rem;
	width: 2.75rem;
	place-items: center;
	border: 1px solid hsl(var(--sidebar-primary) / 0.65);
	border-radius: 0.625rem;
	background: hsl(var(--sidebar-primary-foreground));
	padding: 0.25rem;
}

.brand-mark :global(img) {
	max-height: 100%;
	max-width: 100%;
	object-fit: contain;
}

.brand-kicker {
	margin: 0 0 0.125rem;
	color: hsl(var(--sidebar-primary));
	font-size: 0.5625rem;
	font-weight: 800;
	letter-spacing: 0.14em;
	text-transform: uppercase;
}

h2 {
	margin: 0;
	color: hsl(var(--sidebar-foreground));
	font-family: Georgia, "Times New Roman", serif;
	font-size: 1.125rem;
	font-weight: 700;
	letter-spacing: -0.025em;
}

.nav-group-label {
	color: hsl(var(--sidebar-foreground) / 0.5);
	font-size: 0.625rem;
	font-weight: 800;
	letter-spacing: 0.14em;
	text-transform: uppercase;
}

.nav-item {
	font-weight: 600;
	transition:
		background-color 180ms ease-out,
		color 180ms ease-out,
		transform 180ms ease-out;
}

.nav-item:hover {
	transform: translateX(2px);
}

.member-note {
	display: flex;
	align-items: center;
	gap: 0.5rem;
	margin: 0.5rem;
	color: hsl(var(--sidebar-foreground) / 0.55);
	font-size: 0.6875rem;
	font-weight: 600;
}
</style>
