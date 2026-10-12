<!-- PROTOTYPE — throwaway (ALE-372). One Intake: facts, Carried Fee, Seat Hold,
     commands, Intake Email log and history. Rendered in a Sheet (A, B) or inline (C). -->
<script lang="ts">
import {
	AlertTriangle,
	Baby,
	HeartPulse,
	Link2,
	Mail,
	RotateCw,
} from "@lucide/svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import {
	emailType,
	euro,
	fmtDay,
	fmtDayTime,
	fmtTime,
	NOW,
	proto,
	relative,
} from "./bw-prototype-store.svelte";
import IntakeStateBadge from "./intake-state-badge.svelte";
import dayjs from "dayjs";

let { intakeId, dense = false }: { intakeId: string; dense?: boolean } =
	$props();

const intake = $derived(proto.intake(intakeId));
const person = $derived(proto.person(intake.personId));
const w = $derived(proto.workshop(intake.workshopId));
const manage = $derived(proto.viewer === "coordinator");
const minor = $derived(proto.isMinorAt(person, w));
const days = $derived(proto.daysToGo(w));
let note = $state("");

const scheduled = $derived.by(() => {
	const out: { label: string; at: string }[] = [];
	if (
		intake.state === "paid" &&
		!intake.emails.some((entry) => entry.type === "pre_workshop") &&
		w.status === "scheduled"
	)
		out.push({ label: "Pre-workshop info", at: w.paymentCutoff });
	if (
		intake.state === "attended" &&
		!intake.emails.some((entry) => entry.type === "follow_up") &&
		w.finalisedAt
	)
		out.push({
			label: "Follow-up",
			at: dayjs(w.finalisedAt).add(1, "day").hour(10).minute(0).toISOString(),
		});
	return out;
});

function run(result: { ok: boolean }) {
	if (result.ok) note = "";
}
</script>

<div class="flex flex-col gap-5 text-sm">
	<header class="flex flex-col gap-2">
		<div class="flex flex-wrap items-center gap-2">
			<h3 class="font-heading text-xl leading-tight">
				{person.firstName}
				{person.lastName}
			</h3>
			{#if person.pronouns}<span class="text-muted-foreground"
					>({person.pronouns})</span
				>{/if}
		</div>
		<div class="flex flex-wrap gap-1.5">
			<IntakeStateBadge {intake} />
			{#if minor}<Badge
					variant="outline"
					class="border-violet-600 text-violet-800"><Baby /> Minor</Badge
				>{/if}
			{#if person.carriedFee}
				<Badge variant="outline" class="border-secondary"
					>Carried Fee: {person.carriedFee.status}</Badge
				>
			{/if}
			<Badge variant="outline"
				>{intake.origin === "fast_track"
					? "Fast-track"
					: `Batch ${intake.batchNo}`}</Badge
			>
		</div>
	</header>

	{#if person.medical}
		<p
			class="flex gap-2 rounded-lg border border-destructive/40 bg-destructive/5 p-2.5"
		>
			<HeartPulse class="size-4 shrink-0 text-destructive" />
			{person.medical}
		</p>
	{/if}

	<dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
		{#if manage}
			<dt class="text-muted-foreground">Email</dt>
			<dd>{person.email}</dd>
			<dt class="text-muted-foreground">Phone</dt>
			<dd>{person.phone || "—"}</dd>
		{/if}
		{#if minor && person.guardian}
			<dt class="text-muted-foreground">Guardian</dt>
			<dd>{person.guardian.name} · {person.guardian.phone}</dd>
		{/if}
		{#if manage}
			<dt class="text-muted-foreground">On Waitlist since</dt>
			<dd>
				{fmtDay(person.registeredAt)}
				{dayjs(person.registeredAt).year()} · {person.standing}
			</dd>
			{#if intake.paidAt}
				<dt class="text-muted-foreground">Paid</dt>
				<dd>
					{intake.paidVia === "carried_fee"
						? "Carried Fee (confirmed)"
						: `${euro(w.fee)} via Stripe`} · {fmtDayTime(intake.paidAt)}
				</dd>
			{/if}
		{/if}
		{#if intake.checkedIn}
			<dt class="text-muted-foreground">Checked in</dt>
			<dd>{fmtTime(intake.checkedIn.at)} by {intake.checkedIn.by}</dd>
		{/if}
	</dl>

	{#if manage && intake.hold}
		<p class="rounded-lg border border-sky-600/40 bg-sky-50 p-2.5 text-sky-900">
			{#if proto.holdLive(intake)}
				Seat Hold open: Stripe checkout in progress, expires {fmtTime(
					intake.hold.expiresAt,
				)} ({relative(intake.hold.expiresAt)}).
			{:else}
				Seat Hold {intake.hold.status} — the seat is released once Stripe ends the
				session.
			{/if}
		</p>
	{/if}

	{#if manage && intake.refund?.status === "failed"}
		<div
			class="flex flex-col gap-2 rounded-lg border-2 border-destructive bg-destructive/5 p-3"
		>
			<p class="flex items-center gap-2 font-semibold text-destructive">
				<AlertTriangle class="size-4" /> Refund of {euro(intake.refund.amount)} failed
			</p>
			<p class="text-muted-foreground">{intake.refund.reason}</p>
			<div class="flex flex-wrap gap-2">
				<Button size="sm" onclick={() => run(proto.retryRefund(intake.id))}
					>Retry refund</Button
				>
				<Button
					size="sm"
					variant="outline"
					onclick={() => run(proto.recordManualRefund(intake.id, note))}
					>Record manual refund</Button
				>
			</div>
		</div>
	{/if}

	{#if manage && intake.refund && intake.refund.status !== "failed"}
		<p class="rounded-lg border bg-muted/50 p-2.5">
			Refunded {euro(intake.refund.amount)}
			{intake.refund.automatic
				? `automatically — ${intake.refund.reason}`
				: intake.refund.manual
					? "manually, outside Stripe"
					: "via Stripe, against the original payment"}.
		</p>
	{/if}

	{#if manage}
		<section class="flex flex-col gap-2">
			<h4
				class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Commands
			</h4>
			{#if intake.state === "paid" && days <= 7 && w.status === "scheduled"}
				<p class="text-xs text-amber-800">
					{days === 0 ? "Workshop is today" : `${days} days to go`} — staff decide
					whether to defer or refund; there's no deadline.
				</p>
			{/if}
			<div class="flex flex-wrap gap-2">
				{#if intake.state === "contacted"}
					{#if person.carriedFee?.status === "held"}
						<Button size="sm" onclick={() => run(proto.confirm(intake.id))}
							>Confirm (Carried Fee)</Button
						>
					{/if}
					<Button
						size="sm"
						variant="outline"
						onclick={() => run(proto.decline(intake.id, note))}>Decline</Button
					>
				{/if}
				{#if intake.state === "paid" && w.status === "scheduled"}
					<Button
						size="sm"
						variant="outline"
						onclick={() => run(proto.defer(intake.id, note))}
						>Defer (keep fee)</Button
					>
					<Button
						size="sm"
						variant="outline"
						onclick={() => run(proto.cancelWithRefund(intake.id, note))}
						>Cancel with refund</Button
					>
				{/if}
				{#if (intake.state === "contacted" || intake.state === "paid") && w.status === "scheduled"}
					<Button
						size="sm"
						variant="outline"
						class="text-destructive"
						onclick={() =>
							(proto.dialog = { kind: "withdraw", intakeId: intake.id })}
						>Withdraw…</Button
					>
				{/if}
				{#if person.carriedFee && ["held", "applied"].includes(person.carriedFee.status) && intake.state !== "attended"}
					<Button
						size="sm"
						variant="outline"
						onclick={() => run(proto.refundCarriedFee(person.id, intake.id))}
						>Refund Carried Fee</Button
					>
				{/if}
				{#if w.status === "finalised" && intake.state === "no_show"}
					<Button
						size="sm"
						variant="outline"
						onclick={() =>
							run(proto.correctAttendance(intake.id, "attended", note))}
						>Correct → attended</Button
					>
					<Button
						size="sm"
						variant="outline"
						onclick={() =>
							run(proto.correctAttendance(intake.id, "deferred", note))}
						>Correct → deferred</Button
					>
				{/if}
				{#if w.status === "finalised" && intake.state === "attended"}
					{#if ["invited", "joined"].includes(person.standing)}
						<p class="w-full text-xs text-muted-foreground">
							{person.standing === "invited" ? "Invited" : "Joined"}: attendance
							can no longer be corrected.
						</p>
					{:else}
						<Button
							size="sm"
							variant="outline"
							onclick={() =>
								run(proto.correctAttendance(intake.id, "no_show", note))}
							>Correct → no-show</Button
						>
						<Button
							size="sm"
							onclick={() => run(proto.sendInvitation(person.id))}
							>Invite</Button
						>
					{/if}
					{#if proto.inviteRefusals[person.id]}
						<p class="w-full text-xs text-destructive">
							Invite refused: {proto.inviteRefusals[person.id]}
						</p>
					{/if}
				{/if}
			</div>
			{#if intake.state === "contacted" || intake.state === "paid"}
				<div class="flex flex-wrap items-center gap-2">
					<Button
						size="sm"
						variant="ghost"
						onclick={() => run(proto.resendLink(intake.id))}
						><Mail /> Resend link</Button
					>
					<Button
						size="sm"
						variant="ghost"
						onclick={() => run(proto.rotateLink(intake.id))}
						><RotateCw /> Rotate link</Button
					>
					<span class="flex items-center gap-1 text-xs text-muted-foreground"
						><Link2 class="size-3" /> link generation {intake.linkGeneration}</span
					>
				</div>
			{/if}
			<Textarea
				bind:value={note}
				rows={dense ? 1 : 2}
				placeholder="Note recorded with the next command (optional), e.g. “Replied 9 Oct: moving to Cork”"
				class="text-sm"
			/>
		</section>

		<section class="flex flex-col gap-1.5">
			<h4
				class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Intake Emails
			</h4>
			<ol class="flex flex-col gap-1">
				{#each [...intake.emails].reverse() as entry, index (index)}
					<li
						class="flex items-baseline justify-between gap-3 border-b border-dashed border-border/70 pb-1"
					>
						<span
							>{emailType(entry.type).label}
							<span class="text-xs text-muted-foreground"
								>({emailType(entry.type).kind})</span
							></span
						>
						<span class="shrink-0 text-xs text-muted-foreground"
							>{fmtDayTime(entry.at)}</span
						>
					</li>
				{/each}
				{#each scheduled as entry (entry.label)}
					<li
						class="flex items-baseline justify-between gap-3 text-muted-foreground italic"
					>
						<span>{entry.label} (scheduled)</span>
						<span class="shrink-0 text-xs"
							>{dayjs(entry.at).isAfter(NOW)
								? fmtDayTime(entry.at)
								: "due"}</span
						>
					</li>
				{/each}
			</ol>
			<p class="text-[11px] text-muted-foreground">
				Queued, not delivery status.
			</p>
		</section>

		{#if !dense}
			<section class="flex flex-col gap-1.5">
				<h4
					class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
				>
					History
				</h4>
				<ol class="flex flex-col gap-1.5">
					{#each [...intake.history].reverse() as entry, index (index)}
						<li class="flex flex-col">
							<span><strong>{entry.text}</strong> · {entry.actor}</span>
							<span class="text-xs text-muted-foreground"
								>{fmtDayTime(entry.at)}{#if entry.note}
									— “{entry.note}”{/if}</span
							>
						</li>
					{/each}
				</ol>
			</section>
		{/if}
	{/if}
</div>
