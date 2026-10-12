<!-- PROTOTYPE — throwaway (ALE-372). Seats taken = paid + live Seat Holds. -->
<script lang="ts">
import { cn } from "#lib/utils.js";
import { proto, type Workshop } from "./bw-prototype-store.svelte";

let { workshop, compact = false }: { workshop: Workshop; compact?: boolean } =
	$props();
const seats = $derived(proto.seats(workshop));
const outcome = $derived.by(() => {
	if (workshop.status !== "finalised") return null;
	const list = proto.intakesOf(workshop.id);
	return {
		attended: list.filter((intake) => intake.state === "attended").length,
		noShow: list.filter((intake) => intake.state === "no_show").length,
	};
});
</script>

<div class="flex flex-col gap-1.5">
	<div
		class={cn("flex flex-wrap gap-1", compact && "gap-0.5")}
		aria-hidden="true"
	>
		{#each Array.from({ length: seats.capacity }, (_, index) => index) as index (index)}
			<span
				class={cn(
					"rounded-sm border",
					compact ? "size-2.5" : "size-4",
					outcome
						? index < outcome.attended
							? "border-emerald-700 bg-emerald-600"
							: index < outcome.attended + outcome.noShow
								? "border-destructive bg-destructive/20"
								: "border-border bg-background"
						: index < seats.paid
							? "border-primary bg-primary"
							: index < seats.paid + seats.holds
								? "animate-pulse border-sky-600 bg-sky-200"
								: "border-border bg-background",
				)}
			></span>
		{/each}
	</div>
	{#if outcome}
		<p class={cn("text-muted-foreground", compact ? "text-[11px]" : "text-xs")}>
			<strong class="text-emerald-800">{outcome.attended}</strong> attended ·
			<strong class="text-destructive">{outcome.noShow}</strong>
			no-show of {seats.capacity}
		</p>
	{:else}
		<p class={cn("text-muted-foreground", compact ? "text-[11px]" : "text-xs")}>
			<strong class="text-foreground">{seats.paid}</strong> paid
			{#if seats.holds}· <strong class="text-sky-800">{seats.holds}</strong> paying
				now{/if}
			· <strong class="text-foreground">{seats.free}</strong> free of {seats.capacity}
		</p>
	{/if}
</div>
