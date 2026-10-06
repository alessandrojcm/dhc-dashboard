<script lang="ts">
import type { WaitlistEntry } from "@dhc/api-client";
import { cn } from "#lib/utils.js";

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
};

let { entry, layout }: Props = $props();

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
</div>
