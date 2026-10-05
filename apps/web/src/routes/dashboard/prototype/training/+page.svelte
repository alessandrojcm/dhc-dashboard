<!--
	PROTOTYPE — throwaway (ALE-310)
	Three structurally different Training calendar workflows (plus D, the hybrid asked for after round one) on the throwaway
	`/dashboard/prototype/training` route, switchable via `?variant=`. All three use
	@event-calendar/core in the workshop-calendar visual language and share one
	in-memory Training store and one copy renderer. Nothing here talks to Phoenix.
-->
<script lang="ts">
import { page } from "$app/state";
import PrototypeSwitcher from "$lib/components/ui/prototype-switcher.svelte";
import "./training-prototype.css";
import VariantA from "./variant-a-month-grid.svelte";
import VariantB from "./variant-b-rail-week.svelte";
import VariantC from "./variant-c-post-feed.svelte";
import VariantD from "./variant-d-hybrid.svelte";

const variants = [
	{ id: "A", label: "A — Month grid + occurrence inspector" },
	{ id: "B", label: "B — Trainings rail + week timeline" },
	{ id: "C", label: "C — Post feed" },
	{ id: "D", label: "D — Hybrid: B layout + A inspector + Month/Week" },
];

const rawVariant = $derived(page.url.searchParams.get("variant") ?? "A");
const current = $derived(
	variants.some((variant) => variant.id === rawVariant) ? rawVariant : "A",
);
</script>

<svelte:head>
	<title>Training calendar prototype | Dublin HEMA Club</title>
</svelte:head>

<div
	class="mx-auto flex max-w-7xl flex-col gap-6 px-4 py-6 pb-32 sm:px-6 lg:px-8 lg:py-10"
>
	<section
		class="rounded-2xl border-2 border-dashed border-[#ccff00] bg-zinc-950 px-5 py-4 text-[#ccff00] shadow-[0_8px_24px_rgba(0,0,0,0.25)]"
	>
		<p class="text-xs font-bold tracking-[0.16em] uppercase">
			PROTOTYPE — throwaway · ALE-310
		</p>
		<h1 class="mt-2 font-heading text-2xl leading-tight sm:text-3xl">
			Does a separate Training calendar make the whole workflow understandable
			without Workshop concepts?
		</h1>
		<p class="mt-3 max-w-3xl text-sm leading-relaxed text-[#ccff00]/80">
			Try in each variant: add a one-off Training; edit a weekly one; disable
			one; skip one date and a date range; change the copy for a date range
			(then try an overlapping one); find the October bank holiday; open a past
			occurrence and read the delivery outcome. Everything is in memory — reload
			to reset. Fixture "today" is Monday 21 Sep 2026.
		</p>
	</section>

	{#key current}
		{#if current === "B"}
			<VariantB />
		{:else if current === "C"}
			<VariantC />
		{:else if current === "D"}
			<VariantD />
		{:else}
			<VariantA />
		{/if}
	{/key}
</div>

<PrototypeSwitcher {variants} {current} />
