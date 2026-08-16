<script lang="ts">
import type { Snippet } from "svelte";
import DHCLogo from "/src/assets/images/dhc-logo.png?enhanced";

let {
	children,
	eyebrow = "Dublin HEMA Club",
}: {
	children: Snippet;
	eyebrow?: string;
} = $props();
</script>

<div
	class="public-shell min-h-svh overflow-hidden md:grid md:grid-cols-[minmax(20rem,2fr)_3fr]"
>
	<aside
		class="brand-panel relative isolate flex min-h-52 flex-col justify-between overflow-hidden bg-sidebar p-6 text-sidebar-foreground md:min-h-svh md:p-10 lg:p-14"
	>
		<div
			class="brand-grid absolute inset-0 -z-10 opacity-25"
			aria-hidden="true"
		></div>
		<div class="flex items-center gap-3">
			<div
				class="size-14 overflow-hidden rounded-full border-2 border-secondary bg-white shadow-[3px_3px_0_hsl(var(--secondary))]"
			>
				<enhanced:img src={DHCLogo} alt="" class="size-full object-cover" />
			</div>
			<div>
				<p class="text-xs font-bold uppercase tracking-[0.2em] text-secondary">
					{eyebrow}
				</p>
				<p class="font-display text-xl leading-tight">The club desk</p>
			</div>
		</div>

		<div class="hidden max-w-lg md:block">
			<p
				class="mb-4 text-xs font-bold uppercase tracking-[0.24em] text-secondary"
			>
				Train · Organise · Belong
			</p>
			<h1 class="text-4xl leading-[1.05] text-balance lg:text-6xl">
				Old arts.<br />A living club.
			</h1>
			<p
				class="mt-6 max-w-md text-base leading-7 text-sidebar-foreground/75 lg:text-lg"
			>
				Your place for workshops, membership, and the everyday work that keeps
				Dublin HEMA moving.
			</p>
		</div>

		<p
			class="hidden text-xs font-semibold uppercase tracking-[0.18em] text-sidebar-foreground/50 md:block"
		>
			Historical European Martial Arts · Dublin
		</p>
	</aside>

	<main
		id="main-content"
		class="relative flex min-h-[calc(100svh-13rem)] items-start justify-center p-4 sm:p-8 md:min-h-svh md:items-center lg:p-14"
	>
		<div class="w-full max-w-2xl">{@render children()}</div>
	</main>
</div>

<style>
.brand-panel::after {
	content: "";
	position: absolute;
	right: -7rem;
	bottom: -8rem;
	z-index: -1;
	width: 22rem;
	aspect-ratio: 1;
	border: 4rem solid hsl(var(--secondary) / 0.12);
	border-radius: 9999px;
}

.brand-grid {
	background-image:
		linear-gradient(hsl(var(--sidebar-foreground) / 0.12) 1px, transparent 1px),
		linear-gradient(
			90deg,
			hsl(var(--sidebar-foreground) / 0.12) 1px,
			transparent 1px
		);
	background-size: 40px 40px;
	mask-image: linear-gradient(to bottom right, black, transparent 70%);
}
</style>
