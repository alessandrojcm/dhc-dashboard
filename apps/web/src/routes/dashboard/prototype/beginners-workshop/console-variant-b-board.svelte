<!-- PROTOTYPE — throwaway (ALE-372).
     Variant B — Pipeline board: one column per Intake state, left to right through the
     lifecycle, with the proposed next Batch as a ghost column. No drag: the closed command
     set decides every move, so a card only moves through its commands (in the Sheet). -->
<script lang="ts">
import {
	AlertTriangle,
	ArrowLeft,
	Baby,
	CalendarClock,
	DoorOpen,
	HeartPulse,
	Send,
	UserPlus,
	Users,
	XCircle,
} from "@lucide/svelte";
import dayjs from "dayjs";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { cn } from "#lib/utils.js";
import { go } from "./bw-nav";
import {
	euro,
	fmtDay,
	fmtDayTime,
	fmtTime,
	type Intake,
	NOW,
	proto,
	relative,
	STATE_LABEL,
} from "./bw-prototype-store.svelte";
import IntakeStateBadge from "./intake-state-badge.svelte";
import SeatMeter from "./seat-meter.svelte";

let { workshopId }: { workshopId: string } = $props();
const w = $derived(proto.workshop(workshopId));
const intakes = $derived(proto.intakesOf(w.id));
const proposal = $derived(proto.proposal(w));
const phase = $derived(proto.phase(w));
const scheduled = $derived(w.status === "scheduled");
let showClosed = $state(false);

type Column = {
	key: string;
	title: string;
	hint: string;
	items: Intake[];
	tone: string;
};
const columns = $derived.by<Column[]>(() => {
	const contacted = intakes.filter(
		(intake) => intake.state === "contacted" && !proto.holdLive(intake),
	);
	const paying = intakes.filter(
		(intake) => intake.state === "contacted" && proto.holdLive(intake),
	);
	const paid = intakes.filter((intake) => intake.state === "paid");
	const out: Column[] = [
		{
			key: "contacted",
			title: "Contacted",
			hint: "Can pay while seats remain, until the cutoff",
			items: contacted,
			tone: "border-t-amber-500",
		},
		{
			key: "paying",
			title: "Paying now",
			hint: "Live Seat Hold (30 min)",
			items: paying,
			tone: "border-t-sky-600",
		},
		{
			key: "paid",
			title: w.status === "cancelled" ? "Paid" : "Paid",
			hint: proto.checkInOpen(w)
				? "Tap a card to check in from the Sheet, or use the door view"
				: "Holding a seat",
			items: paid,
			tone: "border-t-primary",
		},
	];
	if (w.status === "finalised") {
		out.push({
			key: "attended",
			title: "Attended",
			hint: "Invite from the card",
			items: intakes.filter((intake) => intake.state === "attended"),
			tone: "border-t-emerald-700",
		});
		out.push({
			key: "no_show",
			title: "No-show",
			hint: "Correct from the card",
			items: intakes.filter((intake) => intake.state === "no_show"),
			tone: "border-t-destructive",
		});
	}
	return out;
});
const closed = $derived(
	intakes.filter(
		(intake) =>
			![
				"contacted",
				"paid",
				...(w.status === "finalised" ? ["attended", "no_show"] : []),
			].includes(intake.state),
	),
);
const closedGroups = $derived(
	[...new Set(closed.map((intake) => intake.state))].map(
		(state) =>
			[state, closed.filter((intake) => intake.state === state)] as const,
	),
);
</script>

{#snippet card(intake: Intake)}
	{@const person = proto.person(intake.personId)}
	{@const refusal = proto.inviteRefusals[person.id]}
	<li>
		<div
			role="button"
			tabindex="0"
			class={cn(
				"flex w-full cursor-pointer flex-col gap-1.5 rounded-xl border bg-card p-3 text-left text-sm shadow-[2px_2px_0_rgb(18_24_39/10%)] hover:border-primary",
				intake.checkedIn && "border-emerald-600 bg-emerald-50",
				intake.refund?.status === "failed" && "border-2 border-destructive",
			)}
			onclick={() => {
				proto.sheetIntakeId = intake.id;
			}}
			onkeydown={(event) =>
				event.key === "Enter" && (proto.sheetIntakeId = intake.id)}
		>
			<div class="flex items-start justify-between gap-2">
				<span class="font-medium">{person.firstName} {person.lastName}</span>
				<span class="flex gap-1">
					{#if proto.isMinorAt(person, w)}<Baby
							class="size-3.5 text-violet-700"
							aria-label="Minor"
						/>{/if}
					{#if person.medical}<HeartPulse
							class="size-3.5 text-destructive"
							aria-label="Medical"
						/>{/if}
				</span>
			</div>
			<div
				class="flex flex-wrap items-center gap-1 text-xs text-muted-foreground"
			>
				<span
					>{intake.origin === "fast_track"
						? "Fast-track"
						: `B${intake.batchNo}`}</span
				>
				{#if intake.state === "contacted" && proto.holdLive(intake)}
					<span class="text-sky-800"
						>· hold ends {fmtTime(intake.hold?.expiresAt as string)}</span
					>
				{:else if intake.state === "contacted"}
					<span
						>· contacted {relative(
							intake.emails[0]?.at ?? NOW.toISOString(),
						)}</span
					>
					{#if person.carriedFee?.status === "held"}<Badge
							variant="outline"
							class="border-secondary text-[10px]">confirms</Badge
						>{/if}
				{:else if intake.state === "paid"}
					<span
						>· {intake.paidVia === "carried_fee" ? "Carried Fee" : "Stripe"}
						{fmtDay(intake.paidAt as string)}</span
					>
					{#if intake.checkedIn}<span class="text-emerald-800"
							>· in {fmtTime(intake.checkedIn.at)}</span
						>{/if}
				{:else if intake.state === "attended"}
					<Badge variant="outline" class="text-[10px]">{person.standing}</Badge>
				{/if}
			</div>
			{#if intake.state === "attended" && person.standing === "attended"}
				<Button
					size="sm"
					variant="outline"
					class="h-8 w-fit"
					onclick={(event: MouseEvent) => {
						event.stopPropagation();
						proto.sendInvitation(person.id);
					}}>Invite</Button
				>
				{#if person.invitationNote}<span
						class="text-[11px] text-muted-foreground"
						>{person.invitationNote}</span
					>{/if}
			{/if}
			{#if refusal}<span class="text-[11px] text-destructive"
					>Invite refused: {refusal}</span
				>{/if}
		</div>
	</li>
{/snippet}

<div class="flex flex-col gap-4">
	<div class="flex flex-wrap items-center gap-x-4 gap-y-2">
		<button
			type="button"
			class="flex cursor-pointer items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
			onclick={() => go("workshops")}
		>
			<ArrowLeft class="size-4" /> All
		</button>
		<h1 class="font-heading text-2xl">
			{dayjs(w.date).format("ddd D MMM")} · {w.startTime}
		</h1>
		<Badge
			variant="outline"
			class={w.status === "cancelled"
				? "border-destructive text-destructive"
				: "border-secondary bg-secondary/20"}>{proto.phaseLabel(w)}</Badge
		>
		<span class="text-sm text-muted-foreground"
			>{w.venue} · {euro(w.fee)} · cutoff {fmtDayTime(w.paymentCutoff)}</span
		>
	</div>

	<div class="flex flex-wrap gap-2">
		{#if phase === "check_in_open" || phase === "today_before_check_in"}
			<Button onclick={() => go("door", w.id)}><DoorOpen /> Door view</Button>
			{#if phase === "check_in_open"}<Button
					variant="outline"
					onclick={() => {
						proto.dialog = { kind: "finish", workshopId: w.id };
					}}>Finish workshop…</Button
				>{/if}
		{/if}
		<Button
			variant="outline"
			disabled={!scheduled}
			onclick={() => {
				proto.dialog = { kind: "fast_track", workshopId: w.id };
			}}><UserPlus /> Fast-track</Button
		>
		<Button
			variant="outline"
			disabled={!scheduled}
			onclick={() => {
				proto.dialog = { kind: "staff", workshopId: w.id };
			}}><Users /> Staff</Button
		>
		<Button
			variant="outline"
			disabled={!scheduled}
			onclick={() => {
				proto.dialog = { kind: "settings", workshopId: w.id };
			}}>Capacity · fee · cutoff</Button
		>
		<Button
			variant="outline"
			disabled={!scheduled}
			onclick={() => {
				proto.dialog = { kind: "reschedule", workshopId: w.id };
			}}><CalendarClock /> Reschedule</Button
		>
		<Button
			variant="ghost"
			class="text-destructive"
			disabled={!scheduled}
			onclick={() =>
				(proto.dialog = { kind: "cancel_workshop", workshopId: w.id })}
			><XCircle /> Cancel</Button
		>
	</div>

	<div class="grid gap-4 2xl:grid-cols-[1fr_16rem]">
		<div class="min-w-0 overflow-x-auto pb-2">
			<div class="flex min-w-max gap-3">
				{#if scheduled && !proto.afterCutoff(w)}
					<section
						class="flex w-52 flex-col gap-2 rounded-2xl border-2 border-dashed border-secondary bg-secondary/10 p-3"
					>
						<header class="flex flex-col gap-1">
							<h2 class="text-sm font-bold">
								Next Batch {(proto.lastBatch(w)?.no ?? 0) + 1}
								<span class="font-normal text-muted-foreground">(proposed)</span
								>
							</h2>
							<p class="text-[11px] text-muted-foreground">
								{phase === "window_open"
									? `Ready after the window ends ${fmtDay(proto.lastBatch(w)?.windowEnd as string)}`
									: `${proposal.length} = capacity − paid`}
							</p>
							<Button
								size="sm"
								disabled={!proposal.length || phase === "window_open"}
								onclick={() =>
									(proto.dialog = { kind: "send_batch", workshopId: w.id })}
								><Send /> Send…</Button
							>
						</header>
						<ol class="flex flex-col gap-1">
							{#each proposal as person, index (person.id)}
								<li
									class="flex items-center gap-2 rounded-lg border border-dashed bg-background/70 px-2 py-1 text-xs text-muted-foreground"
								>
									<span class="w-4 tabular-nums">{index + 1}</span
									>{person.firstName}
									{person.lastName}
									{#if person.carriedFee?.status === "held"}<Badge
											variant="outline"
											class="ml-auto border-secondary text-[10px]">CF</Badge
										>{/if}
								</li>
							{/each}
						</ol>
					</section>
				{/if}
				{#each columns as column (column.key)}
					<section
						class={cn(
							"flex w-52 flex-col gap-2 rounded-2xl border border-t-4 bg-muted/40 p-3",
							column.tone,
						)}
					>
						<header>
							<h2 class="text-sm font-bold">
								{column.title}
								<span class="font-normal text-muted-foreground"
									>{column.items.length}</span
								>
							</h2>
							<p class="text-[11px] text-muted-foreground">{column.hint}</p>
						</header>
						<ul class="flex flex-col gap-2">
							{#each column.items as intake (intake.id)}{@render card(
									intake,
								)}{/each}
						</ul>
					</section>
				{/each}
				<section
					class="flex w-44 flex-col gap-2 rounded-2xl border border-t-4 border-t-border bg-muted/20 p-3"
				>
					<button
						type="button"
						class="cursor-pointer text-left"
						onclick={() => (showClosed = !showClosed)}
					>
						<h2 class="text-sm font-bold">
							Closed <span class="font-normal text-muted-foreground"
								>{closed.length}</span
							>
						</h2>
						<p class="text-[11px] text-muted-foreground">
							{showClosed ? "Hide" : "Show"} people
						</p>
					</button>
					{#each closedGroups as [state, group] (state)}
						<div class="flex flex-col gap-1">
							<p class="text-xs font-semibold">
								{STATE_LABEL[state]} · {group.length}
							</p>
							{#if showClosed}
								<ul class="flex flex-col gap-1.5">
									{#each group as intake (intake.id)}{@render card(
											intake,
										)}{/each}
								</ul>
							{/if}
						</div>
					{/each}
				</section>
			</div>
		</div>

		<aside
			class="grid content-start gap-4 sm:grid-cols-2 lg:grid-cols-4 2xl:flex 2xl:flex-col"
		>
			{#each proto
				.alerts(w)
				.filter((alert) => alert.tone !== "info") as alert (alert.text)}
				<button
					type="button"
					class={cn(
						"flex cursor-pointer items-start gap-2 rounded-xl border-2 p-3 text-left text-sm",
						alert.tone === "error"
							? "border-destructive bg-destructive/5"
							: "border-amber-500 bg-amber-50",
					)}
					onclick={() => {
						if (alert.intakeId) proto.sheetIntakeId = alert.intakeId;
						else proto.dialog = { kind: "staff", workshopId: w.id };
					}}
				>
					<AlertTriangle class="mt-0.5 size-4 shrink-0" />
					{alert.text}
				</button>
			{/each}
			<div class="rounded-2xl border bg-card p-3">
				<SeatMeter workshop={w} />
			</div>
			<div class="rounded-2xl border bg-card p-3 text-sm">
				<h3
					class="mb-1 text-xs font-bold tracking-wider text-muted-foreground uppercase"
				>
					Staff
				</h3>
				<p>
					{proto.staffName(w.coachId) ?? "No coach"}
					<span class="text-muted-foreground">(coach)</span>
				</p>
				{#each w.assistantIds as id (id)}<p>{proto.staffName(id)}</p>{/each}
			</div>
			<div class="rounded-2xl border bg-card p-3 text-sm">
				<h3
					class="mb-1 text-xs font-bold tracking-wider text-muted-foreground uppercase"
				>
					Batches
				</h3>
				{#each w.batches as batch (batch.no)}
					<p>
						B{batch.no}: {batch.size} · window {dayjs(batch.windowEnd).isAfter(
							NOW,
						)
							? "→"
							: "ended"}
						{fmtDay(batch.windowEnd)}
					</p>
				{:else}<p class="text-muted-foreground">None yet</p>{/each}
			</div>
		</aside>
	</div>
</div>
