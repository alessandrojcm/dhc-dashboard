<script lang="ts">
import { page } from "$app/state";
import { cn } from "$lib/utils";
import { BarChart3, Mail, Users } from "@lucide/svelte";
import type { LayoutProps } from "./$types";
import InviteDrawer from "./invite-drawer.svelte";
import SettingsSheet from "./settings-sheet.svelte";

const { children, data }: LayoutProps = $props();

const sections = [
	{
		label: "Overview",
		href: "/dashboard/members",
		icon: BarChart3,
	},
	{
		label: "Members",
		href: "/dashboard/members/directory",
		icon: Users,
	},
	{
		label: "Invitations",
		href: "/dashboard/members/invitations",
		icon: Mail,
	},
] as const;

const pathname = $derived(page.url.pathname);

function isActive(href: (typeof sections)[number]["href"]): boolean {
	if (href === "/dashboard/members") return pathname === href;
	if (href === "/dashboard/members/invitations") {
		return pathname.startsWith(href);
	}
	return (
		pathname.startsWith(href) ||
		(pathname.startsWith("/dashboard/members/") &&
			!pathname.startsWith("/dashboard/members/invitations"))
	);
}
</script>

<svelte:head>
	<title>Members | Dublin HEMA Club</title>
</svelte:head>

<div class="h-[calc(100dvh-57px)] overflow-y-auto px-4 pb-8 sm:px-6 lg:px-8">
	<div class="mx-auto w-full max-w-7xl">
		<header class="flex flex-col gap-5 py-6 sm:py-8">
			<div class="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
				<div class="max-w-2xl">
					<p
						class="mb-2 text-xs font-bold uppercase tracking-[0.18em] text-primary"
					>
						Club administration
					</p>
					<h1 class="font-heading text-3xl text-foreground sm:text-4xl">
						Members
					</h1>
					<p class="mt-2 text-sm leading-6 text-muted-foreground sm:text-base">
						Manage membership records, invitations, and club settings.
					</p>
				</div>

				{#if data.canEditSettings}
					<div class="flex flex-wrap items-center gap-2">
						<SettingsSheet initialValue={data.membersInsuranceFormLink} />
						<InviteDrawer />
					</div>
				{/if}
			</div>

			<nav
				aria-label="Members sections"
				class="grid grid-cols-3 gap-1 rounded-xl border border-border bg-card p-1.5 shadow-[3px_3px_0_hsl(var(--secondary)/0.45)]"
			>
				{#each sections as section (section.href)}
					{@const active = isActive(section.href)}
					<a
						href={section.href}
						aria-current={active ? "page" : undefined}
						class={cn(
							"flex min-h-11 cursor-pointer items-center justify-center gap-2 rounded-lg px-2 text-sm font-semibold transition-[color,background-color,box-shadow] duration-200 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 sm:px-4",
							active
								? "bg-primary text-primary-foreground shadow-sm"
								: "text-muted-foreground hover:bg-primary/5 hover:text-foreground",
						)}
					>
						<section.icon class="hidden size-4 sm:block" aria-hidden="true" />
						<span>{section.label}</span>
					</a>
				{/each}
			</nav>
		</header>

		<div class="pb-4">
			{@render children()}
		</div>
	</div>
</div>
