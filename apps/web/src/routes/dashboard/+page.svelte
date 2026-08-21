<script lang="ts">
import type { PageData } from "./$types";
import {
	ArrowUpRight,
	Boxes,
	CalendarDays,
	GraduationCap,
	ShieldCheck,
	Swords,
	UsersRound,
} from "@lucide/svelte";

let { data }: { data: PageData } = $props();

const navIcons = {
	"Beginners Workshop": GraduationCap,
	Members: UsersRound,
	Workshops: CalendarDays,
	"My Workshops": Swords,
	Inventory: Boxes,
};

const descriptions = {
	"Beginners Workshop": "Manage the beginners course and waiting list.",
	Members: "View and manage club members.",
	Workshops: "Create workshops and manage registrations.",
	"My Workshops": "View your upcoming and previous workshops.",
	Inventory: "Track weapons, protective kit, storage, and maintenance.",
};
</script>

<svelte:head>
	<title>Dashboard | Dublin HEMA Club</title>
	<meta
		name="description"
		content="Your Dublin HEMA Club workspace for members, workshops, and equipment."
	/>
</svelte:head>

<div class="space-y-10 p-4 pb-12 sm:p-6 lg:p-10">
	<section
		class="hero-grid relative isolate overflow-hidden rounded-3xl bg-sidebar px-6 py-10 text-sidebar-foreground shadow-[var(--shadow-block-strong)] sm:px-10 lg:px-14 lg:py-14"
	>
		<div
			class="absolute inset-y-0 right-0 -z-10 hidden w-2/5 border-l border-sidebar-border bg-secondary lg:block"
			aria-hidden="true"
		></div>
		<div class="max-w-3xl">
			<div
				class="mb-6 inline-flex items-center gap-2 rounded-full border border-secondary/40 bg-secondary/10 px-3 py-1.5 text-xs font-bold uppercase tracking-[0.18em] text-secondary"
			>
				<ShieldCheck class="size-4" /> Dashboard
			</div>
			<h1 class="text-4xl leading-[1.05] text-balance sm:text-5xl lg:text-7xl">
				Dublin HEMA Club
			</h1>
			<p
				class="mt-6 max-w-2xl text-base leading-7 text-sidebar-foreground/72 sm:text-lg"
			>
				Manage members, workshops, the beginners course, and club equipment.
			</p>
		</div>
		<div
			class="mt-10 flex items-center gap-3 text-sm font-semibold text-sidebar-foreground/70 lg:absolute lg:bottom-10 lg:right-12 lg:max-w-[14rem] lg:text-sidebar-primary-foreground"
		>
			<span class="size-2 shrink-0 rounded-full bg-secondary"></span>
			{data.navData.navMain.length} sections available
		</div>
	</section>

	<section aria-labelledby="workspace-heading">
		<div class="mb-5 flex items-end justify-between gap-4">
			<div>
				<p class="text-xs font-bold uppercase tracking-[0.2em] text-primary">
					Your workspace
				</p>
				<h2 id="workspace-heading" class="mt-1 text-3xl sm:text-4xl">
					Where do you want to start?
				</h2>
			</div>
		</div>

		<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
			{#each data.navData.navMain as item, index (item.title)}
				{@const Icon =
					navIcons[item.title as keyof typeof navIcons] ?? ArrowUpRight}
				<a
					href={item.url}
					class="group flex min-h-52 cursor-pointer flex-col justify-between rounded-2xl border border-border/80 bg-card p-6 text-card-foreground shadow-[var(--shadow-block)] transition-[transform,box-shadow,border-color] duration-200 hover:-translate-y-1 hover:border-primary hover:shadow-[var(--shadow-block-strong)] focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring/50"
				>
					<div class="flex items-start justify-between gap-4">
						<div
							class="flex size-12 items-center justify-center rounded-xl bg-primary text-primary-foreground"
						>
							<Icon class="size-6" />
						</div>
						<span class="font-display text-4xl text-muted">0{index + 1}</span>
					</div>
					<div>
						<div class="flex items-center justify-between gap-3">
							<h3 class="text-2xl">{item.title}</h3>
							<ArrowUpRight
								class="size-5 text-primary transition-transform duration-200 group-hover:translate-x-1 group-hover:-translate-y-1"
							/>
						</div>
						<p class="mt-2 text-sm leading-6 text-muted-foreground">
							{descriptions[item.title as keyof typeof descriptions] ??
								"Open this section."}
						</p>
					</div>
				</a>
			{/each}
		</div>
	</section>
</div>

<style>
.hero-grid::before {
	content: "";
	position: absolute;
	inset: 0;
	z-index: -1;
	background-image:
		linear-gradient(hsl(var(--sidebar-foreground) / 0.06) 1px, transparent 1px),
		linear-gradient(
			90deg,
			hsl(var(--sidebar-foreground) / 0.06) 1px,
			transparent 1px
		);
	background-size: 48px 48px;
	mask-image: linear-gradient(to right, black, transparent 75%);
}
</style>
