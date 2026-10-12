<!-- PROTOTYPE — throwaway (ALE-372).
     Variant C — Next-action cockpit: a lifecycle timeline on the left, a "Now" card with
     the one thing to do at this moment, what needs attention, then the roster grouped by
     meaning (seated / asked / out) with Intakes expanding inline instead of in a Sheet. -->
<script lang="ts">
import {
	AlertTriangle,
	ArrowLeft,
	Check,
	ChevronDown,
	Circle,
	CircleDot,
	DoorOpen,
	Send,
	UserPlus,
} from "@lucide/svelte";
import dayjs from "dayjs";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { cn } from "#lib/utils.js";
import { go } from "./bw-nav";
import {
	euro,
	fmtDay,
	fmtDayLong,
	fmtDayTime,
	type Intake,
	must,
	NOW,
	proto,
} from "./bw-prototype-store.svelte";
import IntakeDetail from "./intake-detail.svelte";
import IntakeStateBadge from "./intake-state-badge.svelte";
import SeatMeter from "./seat-meter.svelte";
import WorkshopMenu from "./workshop-menu.svelte";

let { workshopId }: { workshopId: string } = $props();
const w = $derived(proto.workshop(workshopId));
const intakes = $derived(proto.intakesOf(w.id));
const phase = $derived(proto.phase(w));
const proposal = $derived(proto.proposal(w));
const seats = $derived(proto.seats(w));
const nextBatch = $derived((proto.lastBatch(w)?.no ?? 0) + 1);
let expanded = $state<string | null>(null);

type Step = {
	label: string;
	when?: string;
	detail?: string;
	state: "done" | "now" | "next" | "skipped";
};
const steps = $derived.by<Step[]>(() => {
	const cancelled = w.status === "cancelled";
	const out: Step[] = [
		{
			label: "Scheduled",
			detail: w.coachId ? `Coach ${proto.staffName(w.coachId)}` : "Unstaffed",
			state: "done",
		},
	];
	for (const batch of w.batches) {
		const open = dayjs(batch.windowEnd).isAfter(NOW) && !cancelled;
		out.push({
			label: `Batch ${batch.no} · ${batch.size} contacted`,
			when: `${fmtDay(batch.sentAt)} → ${fmtDay(batch.windowEnd)}`,
			state: open ? "now" : "done",
		});
	}
	if (phase === "no_batch" || phase === "next_batch_ready")
		out.push({
			label: `Batch ${nextBatch} · ${proposal.length} proposed`,
			state: "now",
		});
	const afterCutoff = proto.afterCutoff(w);
	out.push({
		label: "Payment Cutoff · pre-workshop info",
		when: fmtDayTime(w.paymentCutoff),
		detail: w.preWorkshopSentAt ? `Sent to ${seats.paid}` : undefined,
		state: cancelled
			? "skipped"
			: afterCutoff
				? phase === "payment_closed"
					? "now"
					: "done"
				: "next",
	});
	out.push({
		label:
			"Workshop · check-in from " + proto.checkInOpensAt(w).format("HH:mm"),
		when: fmtDayLong(w.date),
		state: cancelled
			? "skipped"
			: phase === "check_in_open" || phase === "today_before_check_in"
				? "now"
				: w.status === "finalised"
					? "done"
					: "next",
	});
	out.push({
		label: "Attendance Finalisation",
		when: w.finalisedAt
			? `${fmtDayTime(w.finalisedAt)} · ${w.finalisedBy}`
			: "door “Finish”, or end of day",
		state: cancelled ? "skipped" : w.status === "finalised" ? "done" : "next",
	});
	out.push({
		label: "Follow-up email",
		when: w.followUpSentAt
			? fmtDayTime(w.followUpSentAt)
			: "10:00 next morning",
		state: cancelled ? "skipped" : w.followUpSentAt ? "done" : "next",
	});
	const toInvite = intakes.filter(
		(intake) =>
			intake.state === "attended" &&
			proto.person(intake.personId).standing === "attended",
	).length;
	out.push({
		label: "Invitations",
		detail:
			w.status === "finalised"
				? `${toInvite} still Invitable`
				: "open at finalisation",
		state: cancelled
			? "skipped"
			: w.status === "finalised"
				? toInvite
					? "now"
					: "done"
				: "next",
	});
	if (cancelled)
		out.push({
			label: "Cancelled",
			when: fmtDayTime(must(w.cancelledAt)),
			state: "done",
		});
	return out;
});

const groups = $derived.by(() => {
	const finalised = w.status === "finalised";
	return [
		{
			key: "seated",
			title: finalised ? "Attended" : "Seated (paid)",
			items: intakes.filter((intake) =>
				finalised ? intake.state === "attended" : intake.state === "paid",
			),
		},
		{
			key: "asked",
			title: finalised ? "No-show" : "Asked, not paid yet",
			items: intakes.filter((intake) =>
				finalised ? intake.state === "no_show" : intake.state === "contacted",
			),
		},
		{
			key: "out",
			title: "Out of this workshop",
			items: intakes.filter(
				(intake) =>
					![
						"paid",
						"contacted",
						...(finalised ? ["attended", "no_show"] : []),
					].includes(intake.state),
			),
		},
	];
});

const contactedUnpaid = $derived(
	intakes.filter((intake) => intake.state === "contacted"),
);
const toConfirm = $derived(
	contactedUnpaid.filter(
		(intake) => proto.person(intake.personId).carriedFee?.status === "held",
	),
);
const checkedIn = $derived(intakes.filter((intake) => intake.checkedIn).length);
const invitable = $derived(
	intakes.filter(
		(intake) =>
			intake.state === "attended" &&
			proto.person(intake.personId).standing === "attended",
	),
);

const now = $derived.by(() => {
	const last = proto.lastBatch(w);
	switch (phase) {
		case "no_batch":
			return {
				title: `Send Batch 1: ${proposal.length} people are next in the queue`,
				body: "Pick when their payment window ends. Nothing is sent until you press Send.",
			};
		case "window_open":
			return {
				title: `Batch ${last?.no} window open — ends ${fmtDay(must(last).windowEnd)}`,
				body: `${seats.paid} of ${w.capacity} paid${seats.holds ? `, ${seats.holds} paying now` : ""}. The next Batch is proposed when the window ends.`,
			};
		case "next_batch_ready":
			return {
				title: `Batch ${last?.no} window ended — send Batch ${nextBatch} (${proposal.length} people)`,
				body: `${w.capacity - seats.paid} seats unpaid. ${contactedUnpaid.length} already contacted can still pay first-come first-served.`,
			};
		case "full":
			return {
				title: "Full",
				body: `Nothing to do until the Payment Cutoff on ${fmtDayTime(w.paymentCutoff)}.`,
			};
		case "payment_closed":
			return {
				title: `Payment closed — workshop in ${proto.daysToGo(w)} days`,
				body: `Pre-workshop info went to ${seats.paid} people on ${fmtDayTime(w.preWorkshopSentAt ?? w.paymentCutoff)}.`,
			};
		case "today_before_check_in":
			return {
				title: `Today — check-in opens ${proto.checkInOpensAt(w).format("HH:mm")}`,
				body: "Staff open the door view on their phone.",
			};
		case "check_in_open":
			return {
				title: `Check-in open: ${checkedIn} of ${seats.paid} in`,
				body: "Staff run the door view. Finish when the session starts; otherwise it finalises at midnight.",
			};
		case "awaiting_finalisation":
			return {
				title: "Awaiting finalisation",
				body: "Finalises automatically at the end of the workshop day.",
			};
		case "finalised":
			return {
				title: `${groups[0]?.items.length} attended · ${invitable.length} to invite`,
				body: `Follow-up ${w.followUpSentAt ? `sent ${fmtDayTime(w.followUpSentAt)}` : "goes out at 10:00 tomorrow"}. Invite each person below; eligibility doesn't wait for the follow-up.`,
			};
		case "cancelled":
			return {
				title: `Cancelled ${fmtDay(must(w.cancelledAt))}`,
				body: "Paid people were deferred with a Carried Fee; unpaid people went back to the Waitlist. If someone replies asking for their money back, refund their Carried Fee from their row.",
			};
	}
});
</script>

{#snippet stepIcon(state: Step["state"])}
	{#if state === "done"}<Check class="size-4 text-emerald-700" />
	{:else if state === "now"}<CircleDot
			class="size-4 text-secondary-foreground"
		/>
	{:else}<Circle
			class={cn(
				"size-4",
				state === "skipped" ? "text-border" : "text-muted-foreground",
			)}
		/>{/if}
{/snippet}

{#snippet rosterRow(intake: Intake)}
	{@const person = proto.person(intake.personId)}
	<li class="rounded-xl border bg-card">
		<button
			type="button"
			class="flex w-full cursor-pointer items-center gap-3 px-3 py-2 text-left text-sm"
			onclick={() => (expanded = expanded === intake.id ? null : intake.id)}
		>
			<span class="flex-1 font-medium"
				>{person.firstName} {person.lastName}</span
			>
			{#if proto.inviteRefusals[person.id]}<span
					class="text-xs text-destructive"
					>{proto.inviteRefusals[person.id]}</span
				>{/if}
			<IntakeStateBadge {intake} />
			<ChevronDown
				class={cn(
					"size-4 text-muted-foreground transition",
					expanded === intake.id && "rotate-180",
				)}
			/>
		</button>
		{#if expanded === intake.id}
			<div class="border-t px-3 py-3">
				<IntakeDetail intakeId={intake.id} dense />
			</div>
		{/if}
	</li>
{/snippet}

<div class="grid gap-6 lg:grid-cols-[19rem_1fr]">
	<aside class="flex flex-col gap-4">
		<button
			type="button"
			class="flex w-fit cursor-pointer items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
			onclick={() => go("workshops")}
		>
			<ArrowLeft class="size-4" /> Beginners' Workshops
		</button>
		<div>
			<h1 class="font-heading text-2xl leading-tight">{fmtDayLong(w.date)}</h1>
			<p class="text-sm text-muted-foreground">
				{w.startTime} · {w.venue} · {euro(w.fee)}
			</p>
		</div>
		<ol class="relative flex flex-col gap-3 border-l-2 border-border pl-4">
			{#each steps as step, index (index)}
				<li
					class={cn(
						"relative",
						step.state === "skipped" && "opacity-40 line-through",
					)}
				>
					<span
						class="absolute top-0.5 -left-[1.6rem] rounded-full bg-background p-0.5"
						>{@render stepIcon(step.state)}</span
					>
					<p
						class={cn(
							"text-sm",
							step.state === "now" ? "font-bold" : "font-medium",
						)}
					>
						{step.label}
					</p>
					{#if step.when}<p class="text-xs text-muted-foreground">
							{step.when}
						</p>{/if}
					{#if step.detail}<p class="text-xs text-muted-foreground">
							{step.detail}
						</p>{/if}
				</li>
			{/each}
		</ol>
		<SeatMeter workshop={w} />
	</aside>

	<div class="flex flex-col gap-5">
		<section
			class="flex flex-col gap-3 rounded-2xl border-2 border-primary bg-card p-5 shadow-[4px_4px_0_var(--color-secondary,#E5B524)]"
		>
			<p
				class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Now
			</p>
			<h2 class="font-heading text-2xl leading-tight">{now.title}</h2>
			<p class="text-sm text-muted-foreground">{now.body}</p>
			<div class="flex flex-wrap gap-2">
				{#if phase === "no_batch" || phase === "next_batch_ready"}
					<Button
						onclick={() =>
							(proto.dialog = { kind: "send_batch", workshopId: w.id })}
						><Send /> Send Batch {nextBatch}…</Button
					>
				{/if}
				{#if phase === "check_in_open" || phase === "today_before_check_in"}
					<Button onclick={() => go("door", w.id)}
						><DoorOpen /> Open door view</Button
					>
					{#if phase === "check_in_open"}<Button
							variant="outline"
							onclick={() =>
								(proto.dialog = { kind: "finish", workshopId: w.id })}
							>Finish workshop…</Button
						>{/if}
				{/if}
				{#if w.status === "scheduled"}
					<Button
						variant="outline"
						onclick={() =>
							(proto.dialog = { kind: "fast_track", workshopId: w.id })}
						><UserPlus /> Fast-track</Button
					>
					<WorkshopMenu workshop={w} label="More" />
				{/if}
			</div>
		</section>

		{#if proto
			.alerts(w)
			.some((alert) => alert.tone !== "info") || toConfirm.length || (phase === "next_batch_ready" && contactedUnpaid.length)}
			<section class="flex flex-col gap-2">
				<h2
					class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
				>
					Needs attention
				</h2>
				{#each proto
					.alerts(w)
					.filter((alert) => alert.tone !== "info") as alert (alert.text)}
					<div
						class={cn(
							"flex items-center gap-3 rounded-xl border-2 p-3 text-sm",
							alert.tone === "error"
								? "border-destructive bg-destructive/5"
								: "border-amber-500 bg-amber-50",
						)}
					>
						<AlertTriangle class="size-4 shrink-0" /><span class="flex-1"
							>{alert.text}</span
						>
						{#if alert.intakeId}
							<Button
								size="sm"
								variant="outline"
								onclick={() => (expanded = alert.intakeId ?? null)}
								>Resolve</Button
							>
						{:else}
							<Button
								size="sm"
								variant="outline"
								onclick={() =>
									(proto.dialog = { kind: "staff", workshopId: w.id })}
								>Assign</Button
							>
						{/if}
					</div>
				{/each}
				{#if toConfirm.length}
					<div class="rounded-xl border p-3 text-sm">
						{toConfirm.length} Carried Fee holders haven't confirmed yet: {toConfirm
							.map((intake) => proto.person(intake.personId).firstName)
							.join(", ")}.
					</div>
				{/if}
				{#if phase === "next_batch_ready" && contactedUnpaid.length}
					<div class="rounded-xl border p-3 text-sm">
						{contactedUnpaid.length} contacted after the window haven't paid — they
						can still pay until the cutoff, competing with Batch {nextBatch}.
					</div>
				{/if}
			</section>
		{/if}

		{#each groups as group (group.key)}
			{#if group.items.length}
				<section class="flex flex-col gap-2">
					<h2
						class="flex items-center gap-2 text-xs font-bold tracking-wider text-muted-foreground uppercase"
					>
						{group.title}
						<Badge variant="outline">{group.items.length}</Badge>
					</h2>
					<ul class="flex flex-col gap-1.5">
						{#each group.items as intake (intake.id)}{@render rosterRow(
								intake,
							)}{/each}
					</ul>
				</section>
			{/if}
		{/each}
	</div>
</div>
