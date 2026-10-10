<!-- ALE-378: Phoenix's seat meter — paid seats, live Seat Holds, free seats. -->
<script lang="ts">
import type { BeginnersWorkshopSeats } from "@dhc/api-client";
import { cn } from "#lib/utils.js";

let { seats }: { seats: BeginnersWorkshopSeats } = $props();

const cells = $derived(
	Array.from({ length: seats.capacity }, (_, index) =>
		index < seats.paid
			? "paid"
			: index < seats.paid + seats.holds
				? "held"
				: "free",
	),
);
</script>

<div class="flex flex-col gap-1.5">
	<div class="flex flex-wrap gap-0.5" aria-hidden="true">
		{#each cells as cell, index (index)}
			<span
				class={cn(
					"size-2.5 rounded-sm border",
					cell === "paid" && "border-primary bg-primary",
					cell === "held" && "border-sky-600 bg-sky-200",
					cell === "free" && "border-border bg-background",
				)}
			></span>
		{/each}
	</div>
	<p class="text-[11px] text-muted-foreground" data-testid="seat-meter">
		<strong class="text-foreground">{seats.paid}</strong> paid
		{#if seats.holds}· <strong class="text-sky-800">{seats.holds}</strong> paying
			now{/if}
		· <strong class="text-foreground">{seats.free}</strong> free of {seats.capacity}
	</p>
</div>
