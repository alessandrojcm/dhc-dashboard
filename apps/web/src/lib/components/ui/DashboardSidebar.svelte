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
import {
	Boxes,
	CalendarDays,
	ChevronRight,
	GraduationCap,
	House,
	Menu,
	Stethoscope,
	Swords,
	UsersRound,
} from "@lucide/svelte";
import { useSidebar } from "$lib/components/ui/sidebar/context.svelte.js";
import { browser } from "$app/environment";
import { resolve } from "$app/paths";
import { page } from "$app/state";

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

const navIcons = {
	"Beginners Workshop": GraduationCap,
	Members: UsersRound,
	"Discord Doctor": Stethoscope,
	Workshops: CalendarDays,
	"My Workshops": Swords,
	Inventory: Boxes,
	Overview: House,
	Containers: Boxes,
	Categories: Boxes,
	Items: Swords,
};

function isActive(url: string) {
	return url === "/dashboard"
		? page.url.pathname === url
		: page.url.pathname === url || page.url.pathname.startsWith(`${url}/`);
}
</script>

<div class="fixed left-3 top-2 z-50 md:hidden">
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
	class="h-svh border-r md:block"
>
	<Sidebar.Header
		class="flex flex-row items-center gap-3 border-b border-sidebar-border px-4 py-5"
	>
		<div
			class="size-11 shrink-0 overflow-hidden rounded-full border-2 border-secondary bg-white"
		>
			<enhanced:img src={DHCLogo} alt="" class="size-full object-cover" />
		</div>
		<div>
			<p
				class="text-[0.65rem] font-bold uppercase tracking-[0.2em] text-secondary"
			>
				Dublin HEMA
			</p>
			<h2 class="text-lg leading-tight text-sidebar-foreground">Dashboard</h2>
		</div>
	</Sidebar.Header>
	<Sidebar.Content data-testid="sidebar" class="px-2 py-4">
		<Sidebar.Group>
			<Sidebar.Menu>
				<Sidebar.MenuItem>
					<Sidebar.MenuButton
						isActive={isActive("/dashboard")}
						tooltipContent="Home"
					>
						{#snippet child({ props })}
							<a
								class={props.class}
								href="/dashboard"
								onclick={toggleSidebar}
								aria-current={isActive("/dashboard") ? "page" : undefined}
							>
								<House /><span>Home</span>
							</a>
						{/snippet}
					</Sidebar.MenuButton>
				</Sidebar.MenuItem>
			</Sidebar.Menu>
		</Sidebar.Group>
		<!-- We create a Sidebar.Group for each parent. -->
		{#each data.navMain as group (group.title)}
			{#if group.role.intersection(roles).size > 0}
				<Sidebar.Group class="py-2">
					{#if group?.items}
						<Sidebar.GroupLabel class="gap-2 text-sidebar-foreground/55">
							{@const GroupIcon =
								navIcons[group.title as keyof typeof navIcons] ?? Boxes}
							<GroupIcon class="size-3.5" />{group.title}
						</Sidebar.GroupLabel>
						<Sidebar.GroupContent>
							<Sidebar.Menu>
								{#each group.items as item (item.title)}
									{#if item.role.intersection(roles).size > 0}
										<Sidebar.MenuItem>
											{@const ItemIcon =
												navIcons[item.title as keyof typeof navIcons] ??
												ChevronRight}
											<Sidebar.MenuButton
												isActive={isActive(item.url)}
												tooltipContent={item.title}
											>
												{#snippet child({ props })}
													<a
														class={props.class}
														href={item.url}
														onclick={toggleSidebar}
														aria-current={isActive(item.url)
															? "page"
															: undefined}
													>
														<ItemIcon /><span>{item.title}</span>
													</a>
												{/snippet}
											</Sidebar.MenuButton>
										</Sidebar.MenuItem>
									{/if}
								{/each}
							</Sidebar.Menu>
						</Sidebar.GroupContent>
					{:else}
						{@const GroupIcon =
							navIcons[group.title as keyof typeof navIcons] ?? ChevronRight}
						<Sidebar.MenuButton
							isActive={isActive(group.url)}
							tooltipContent={group.title}
						>
							{#snippet child({ props })}
								<a
									class={props.class}
									href={group.url}
									onclick={toggleSidebar}
									aria-current={isActive(group.url) ? "page" : undefined}
								>
									<GroupIcon /><span>{group.title}</span>
								</a>
							{/snippet}
						</Sidebar.MenuButton>
					{/if}
				</Sidebar.Group>
			{/if}
		{/each}
	</Sidebar.Content>
	<Sidebar.Footer class="m-2 mb-4 border-t border-sidebar-border pt-3">
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
								<Avatar.Root class="h-8 w-8 border border-secondary/50">
									<Avatar.Fallback
										>{user?.firstName?.charAt(0)}{user?.lastName?.charAt(
											0,
										)}</Avatar.Fallback
									>
								</Avatar.Root>
								<div class="flex min-w-0 flex-col space-y-1">
									<p class="text-sm font-medium leading-none">
										{user?.firstName}
										{user?.lastName}
									</p>
									<p
										class="truncate text-xs leading-none text-sidebar-foreground/55"
									>
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
