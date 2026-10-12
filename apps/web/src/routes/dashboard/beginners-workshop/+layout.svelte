<script lang="ts">
import { page } from "$app/state";
import {
	CalendarDays,
	ChartColumn,
	Mail,
	UserPlus,
	Users,
} from "@lucide/svelte";
import {
	BEGINNERS_WORKSHOP_SECTIONS,
	isBeginnersWorkshopSection,
} from "#lib/beginners-workshops/sections.js";
import { cn } from "#lib/utils.js";
import WaitlistToggle from "./waitlist-toggle.svelte";
import type { LayoutProps } from "./$types";

let { children, data }: LayoutProps = $props();
const isSection = $derived(isBeginnersWorkshopSection(page.route.id));
const icons = {
	dashboard: ChartColumn,
	waitlist: Users,
	workshops: CalendarDays,
	"email-templates": Mail,
	invitable: UserPlus,
};
const sections = $derived(
	BEGINNERS_WORKSHOP_SECTIONS.filter((section) => {
		if (section.id === "workshops" || section.id === "email-templates")
			return data.canManageWorkshops;
		if (section.id === "invitable") return data.canInvite;
		return true;
	}),
);
</script>

<svelte:head><title>Beginners' Workshops | Dublin HEMA Club</title></svelte:head
>

{#if isSection}
	<div class="flex h-full min-h-0 flex-col px-4 pb-3 sm:px-6 lg:px-8">
		<header class="flex shrink-0 flex-col gap-4 py-4 sm:py-6">
			<div class="flex flex-wrap items-center justify-between gap-3">
				<div>
					<p
						class="mb-1 hidden text-xs font-bold uppercase tracking-[0.18em] text-primary sm:block"
					>
						Club administration
					</p>
					<h1 class="font-heading text-2xl text-foreground sm:text-4xl">
						Beginners' Workshops
					</h1>
					<p
						class="mt-2 hidden max-w-2xl text-sm leading-6 text-muted-foreground sm:block"
					>
						Manage the waitlist, workshop places, and membership invitations.
					</p>
				</div>
				{#if data.canToggleWaitlist && data.isWaitlistOpen !== null}<WaitlistToggle
						isOpen={data.isWaitlistOpen}
					/>{/if}
			</div>
			<nav
				aria-label="Beginners' Workshop sections"
				class="flex flex-wrap gap-1 rounded-xl border border-border bg-card p-1.5 shadow-[3px_3px_0_hsl(var(--secondary)/0.45)]"
			>
				{#each sections as section (section.href)}
					{@const active = page.url.pathname === section.href}
					{@const Icon = icons[section.id]}
					<a
						href={section.href}
						aria-current={active ? "page" : undefined}
						class={cn(
							"flex min-h-11 flex-1 basis-24 cursor-pointer items-center justify-center gap-2 rounded-lg px-2 text-sm font-semibold transition-[color,background-color,box-shadow] duration-200 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 sm:px-4",
							active
								? "bg-primary text-primary-foreground shadow-sm"
								: "text-muted-foreground hover:bg-primary/5 hover:text-foreground",
						)}
						><Icon class="hidden size-4 sm:block" aria-hidden="true" /><span
							>{section.label}</span
						></a
					>
				{/each}
			</nav>
		</header>
		<div class="min-h-0 flex-1 overflow-hidden">{@render children()}</div>
	</div>
{:else}
	<div class="h-full min-h-0 overflow-y-auto px-4 pb-8 sm:px-6 lg:px-8">
		{@render children()}
	</div>
{/if}
