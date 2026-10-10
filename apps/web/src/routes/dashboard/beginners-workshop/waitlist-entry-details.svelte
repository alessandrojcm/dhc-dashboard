<script lang="ts">
import type { BeginnersCarriedFeeStatus, WaitlistEntry } from "@dhc/api-client";
import { carriedFeeLabel } from "#lib/beginners-workshops/console.js";
import { Button } from "#lib/components/ui/button/index.js";
import { cn } from "#lib/utils.js";
import CarriedFeePanel from "./carried-fee-panel.svelte";
import type { CarriedFeePanelDeps } from "./carried-fee-panel.svelte.js";

type Props = {
	entry: Pick<
		WaitlistEntry,
		| "guardianFirstName"
		| "guardianLastName"
		| "guardianPhoneNumber"
		| "medicalConditions"
	>;
	/** `table` lays the panels out as bordered cards side by side; `card` stacks them. */
	layout: "table" | "card";
	/** The person's live Carried Fee (ALE-388), from Beginners' Workshops. */
	carriedFee?: BeginnersCarriedFeeStatus | null;
	/**
	 * ALE-389: the person, to manage their Carried Fee (refund, link its
	 * payment, follow up a failed refund). Without it the panel only shows
	 * the status.
	 */
	waitlistId?: string;
	carriedFeeDeps?: CarriedFeePanelDeps;
};

let {
	entry,
	layout,
	carriedFee = null,
	waitlistId,
	carriedFeeDeps,
}: Props = $props();

// Mounted on first open, so the Waitlist asks for no fee details until then.
let managing = $state(false);

const hasGuardian = $derived(
	Boolean(
		entry.guardianFirstName ||
		entry.guardianLastName ||
		entry.guardianPhoneNumber,
	),
);
const panel = $derived(
	layout === "table" ? "bg-card rounded-lg border p-4" : "",
);
</script>

<div
	class={cn(
		layout === "table"
			? "grid grid-cols-1 md:grid-cols-2 gap-4"
			: "flex flex-col gap-4",
	)}
>
	<div class={panel}>
		<h3 class="text-sm font-medium mb-2">Guardian Information</h3>
		{#if hasGuardian}
			<div class="grid grid-cols-3 gap-2">
				<div class="text-xs font-medium text-muted-foreground">Name</div>
				<div class="col-span-2 text-xs">
					{entry.guardianFirstName || ""}
					{entry.guardianLastName || ""}
				</div>

				<div class="text-xs font-medium text-muted-foreground">Phone</div>
				<div class="col-span-2 text-xs">
					{entry.guardianPhoneNumber || "N/A"}
				</div>
			</div>
		{:else}
			<p class="text-xs text-muted-foreground">
				No guardian information available
			</p>
		{/if}
	</div>

	<div class={panel}>
		<h3 class="text-sm font-medium mb-2">Medical Conditions</h3>
		<p class="text-xs">
			{entry.medicalConditions || "None reported"}
		</p>
	</div>

	<div class={panel} data-testid="waitlist-carried-fee">
		<h3 class="text-sm font-medium mb-2">Carried Fee</h3>
		<p class="text-xs">
			{carriedFee === "held"
				? "Held — a prepaid seat: they confirm instead of paying when contacted"
				: carriedFee === "applied"
					? "Applied — it paid their current Intake"
					: (carriedFeeLabel(carriedFee) ?? "None")}
		</p>
		{#if carriedFee && waitlistId}
			{#if managing}
				<div class="mt-2">
					<CarriedFeePanel {waitlistId} deps={carriedFeeDeps} />
				</div>
			{:else}
				<Button
					size="sm"
					variant="outline"
					class="mt-2"
					onclick={() => (managing = true)}>Refund or link payment…</Button
				>
			{/if}
		{/if}
	</div>
</div>
