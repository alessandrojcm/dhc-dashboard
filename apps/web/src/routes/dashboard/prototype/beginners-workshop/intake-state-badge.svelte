<!-- PROTOTYPE — throwaway (ALE-372). Intake state chip shared by every variant. -->
<script lang="ts">
import { Badge } from "#lib/components/ui/badge/index.js";
import { cn } from "#lib/utils.js";
import { type Intake, proto, STATE_LABEL } from "./bw-prototype-store.svelte";

let { intake, class: className }: { intake: Intake; class?: string } = $props();

const live = $derived(proto.holdLive(intake));
const person = $derived(proto.person(intake.personId));

const label = $derived.by(() => {
	if (intake.state === "contacted" && live) return "Paying now";
	if (intake.state === "contacted" && intake.hold?.status === "releasing")
		return "Contacted · hold releasing";
	if (intake.state === "contacted" && person.carriedFee?.status === "held")
		return "Contacted · confirm";
	if (intake.state === "paid" && intake.checkedIn) return "Checked in";
	if (intake.state === "paid" && intake.paidVia === "carried_fee")
		return "Confirmed (Carried Fee)";
	if (
		intake.state === "cancelled_refunded" &&
		intake.refund?.status === "failed"
	)
		return "Refund failed";
	if (intake.state === "deferred") return "Deferred · fee carried";
	return STATE_LABEL[intake.state];
});

const tone = $derived.by(() => {
	if (intake.state === "contacted" && live)
		return "border-sky-600 bg-sky-50 text-sky-900";
	if (intake.state === "contacted")
		return "border-amber-500 bg-amber-50 text-amber-900";
	if (intake.state === "paid" && intake.checkedIn)
		return "border-emerald-700 bg-emerald-600 text-white";
	if (intake.state === "paid")
		return "border-transparent bg-primary text-primary-foreground";
	if (intake.state === "attended")
		return "border-emerald-700 bg-emerald-50 text-emerald-900";
	if (intake.state === "no_show")
		return "border-destructive bg-destructive/5 text-destructive";
	if (intake.refund?.status === "failed")
		return "border-destructive bg-destructive text-white";
	if (intake.state === "deferred")
		return "border-secondary bg-secondary/20 text-foreground";
	return "border-border bg-muted text-muted-foreground";
});
</script>

<Badge variant="outline" class={cn(tone, className)}>
	{#if intake.state === "contacted" && live}
		<span class="size-1.5 animate-pulse rounded-full bg-sky-600"></span>
	{/if}
	{label}
</Badge>
