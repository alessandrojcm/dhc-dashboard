<!-- PROTOTYPE — throwaway (ALE-372).
     Variant A — Tabbed console: facts header, then Roster / Batches / Attended / Closed tabs.
     Commands live in a per-row menu; the row opens the Intake in a side Sheet. -->
<script lang="ts">
import {
	AlertTriangle,
	ArrowLeft,
	Baby,
	DoorOpen,
	Ellipsis,
	HeartPulse,
	Search,
	Send,
} from "@lucide/svelte";
import dayjs from "dayjs";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";

import * as DropdownMenu from "#lib/components/ui/dropdown-menu/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import * as Table from "#lib/components/ui/table/index.js";
import * as Tabs from "#lib/components/ui/tabs/index.js";
import { cn } from "#lib/utils.js";
import { go } from "./bw-nav";
import {
	emailType,
	euro,
	fmtDay,
	fmtDayLong,
	fmtDayTime,
	fmtTime,
	type Intake,
	NOW,
	OPEN_STATES,
	proto,
} from "./bw-prototype-store.svelte";
import IntakeStateBadge from "./intake-state-badge.svelte";
import SeatMeter from "./seat-meter.svelte";
import WorkshopMenu from "./workshop-menu.svelte";

let { workshopId }: { workshopId: string } = $props();
const w = $derived(proto.workshop(workshopId));
const intakes = $derived(proto.intakesOf(w.id));
const finalised = $derived(w.status === "finalised");
const roster = $derived(
	intakes.filter(
		(intake) =>
			OPEN_STATES.includes(intake.state) ||
			(finalised && ["attended", "no_show"].includes(intake.state)),
	),
);
const closed = $derived(intakes.filter((intake) => !roster.includes(intake)));
const attended = $derived(
	intakes.filter((intake) => intake.state === "attended"),
);
const proposal = $derived(proto.proposal(w));
const phase = $derived(proto.phase(w));

const FILTERS = [
	["all", "All"],
	["contacted", "Contacted"],
	["paying", "Paying now"],
	["paid", "Paid"],
	["checked_in", "Checked in"],
] as const;
// After finalisation nobody is contacted, paying or paid any more.
const filterChips = $derived(finalised ? FILTERS.slice(0, 1) : FILTERS);

let tab = $state("roster");
let filter = $state<"all" | "contacted" | "paying" | "paid" | "checked_in">(
	"all",
);
let query = $state("");

const filtered = $derived(
	roster.filter((intake) => {
		const person = proto.person(intake.personId);
		if (
			query &&
			!`${person.firstName} ${person.lastName}`
				.toLowerCase()
				.includes(query.toLowerCase())
		)
			return false;
		if (filter === "contacted")
			return intake.state === "contacted" && !proto.holdLive(intake);
		if (filter === "paying") return proto.holdLive(intake);
		if (filter === "paid") return intake.state === "paid";
		if (filter === "checked_in") return Boolean(intake.checkedIn);
		return true;
	}),
);

const counts = $derived({
	all: roster.length,
	contacted: roster.filter(
		(intake) => intake.state === "contacted" && !proto.holdLive(intake),
	).length,
	paying: roster.filter((intake) => proto.holdLive(intake)).length,
	paid: roster.filter((intake) => intake.state === "paid").length,
	checked_in: roster.filter((intake) => intake.checkedIn).length,
});

function lastEmail(intake: Intake) {
	const entry = intake.emails.at(-1);
	return entry ? `${emailType(entry.type).label} · ${fmtDay(entry.at)}` : "—";
}
</script>

<div class="flex flex-col gap-5">
	<button
		type="button"
		class="flex w-fit cursor-pointer items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
		onclick={() => go("workshops")}
	>
		<ArrowLeft class="size-4" /> Beginners' Workshops
	</button>

	<header class="flex flex-wrap items-start justify-between gap-4">
		<div class="flex flex-col gap-1">
			<div class="flex flex-wrap items-center gap-2">
				<h1 class="font-heading text-3xl leading-tight">
					{fmtDayLong(w.date)}
				</h1>
				<Badge
					variant="outline"
					class={w.status === "cancelled"
						? "border-destructive text-destructive"
						: ""}>{proto.phaseLabel(w)}</Badge
				>
			</div>
			<p class="text-sm text-muted-foreground">
				{fmtTime(`${w.date}T${w.startTime}`)} · {w.venue} · {euro(w.fee)} · Payment
				Cutoff {fmtDayTime(w.paymentCutoff)}
			</p>
		</div>
		<div class="flex flex-wrap gap-2">
			{#if phase === "check_in_open" || phase === "today_before_check_in"}
				<Button onclick={() => go("door", w.id)}><DoorOpen /> Door view</Button>
			{:else if proposal.length && phase !== "window_open"}
				<Button
					onclick={() =>
						(proto.dialog = { kind: "send_batch", workshopId: w.id })}
					><Send /> Send Batch {(proto.lastBatch(w)?.no ?? 0) + 1}</Button
				>
			{/if}
			<WorkshopMenu workshop={w} />
		</div>
	</header>

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
			<AlertTriangle class="size-4 shrink-0" />
			<span class="flex-1">{alert.text}</span>
			{#if alert.intakeId}
				<Button
					size="sm"
					variant="outline"
					onclick={() => {
						proto.sheetIntakeId = alert.intakeId ?? null;
					}}>Open</Button
				>
			{:else}
				<Button
					size="sm"
					variant="outline"
					onclick={() => {
						proto.dialog = { kind: "staff", workshopId: w.id };
					}}>Assign staff</Button
				>
			{/if}
		</div>
	{/each}

	<div class="grid gap-4 md:grid-cols-3">
		<div class="rounded-2xl border bg-card p-4">
			<h2
				class="mb-2 text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Seats
			</h2>
			<SeatMeter workshop={w} />
		</div>
		<div class="rounded-2xl border bg-card p-4">
			<h2
				class="mb-2 text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Staff
			</h2>
			<p class="text-sm">
				<strong>{proto.staffName(w.coachId) ?? "No coach"}</strong> (coach)
			</p>
			<p class="text-sm text-muted-foreground">
				{w.assistantIds.map((id) => proto.staffName(id)).join(", ") ||
					"No assistants"}
			</p>
			{#if finalised}<p class="mt-1 text-xs text-muted-foreground">
					Frozen at finalisation ({w.finalisedBy}, {fmtDayTime(
						w.finalisedAt as string,
					)})
				</p>{/if}
		</div>
		<div class="rounded-2xl border bg-card p-4">
			<h2
				class="mb-2 text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Batches
			</h2>
			{#each w.batches as batch (batch.no)}
				<p class="text-sm">
					Batch {batch.no}: {batch.size} contacted · window {dayjs(
						batch.windowEnd,
					).isAfter(NOW)
						? "until"
						: "ended"}
					{fmtDay(batch.windowEnd)}
				</p>
			{:else}
				<p class="text-sm text-muted-foreground">None sent yet</p>
			{/each}
		</div>
	</div>

	<Tabs.Root bind:value={tab}>
		<Tabs.List>
			<Tabs.Trigger value="roster">Roster ({roster.length})</Tabs.Trigger>
			<Tabs.Trigger value="batches">Batches</Tabs.Trigger>
			{#if finalised}<Tabs.Trigger value="attended"
					>Attended ({attended.length})</Tabs.Trigger
				>{/if}
			<Tabs.Trigger value="closed">Closed ({closed.length})</Tabs.Trigger>
		</Tabs.List>

		<Tabs.Content value="roster" class="flex flex-col gap-3 pt-3">
			<div class="flex flex-wrap items-center gap-2">
				{#each filterChips as [key, label] (key)}
					<button
						type="button"
						class={cn(
							"cursor-pointer rounded-full border px-3 py-1 text-xs font-medium",
							filter === key
								? "border-primary bg-primary text-primary-foreground"
								: "bg-background hover:border-primary",
						)}
						onclick={() => (filter = key)}
					>
						{label}
						{counts[key]}
					</button>
				{/each}
				<div class="relative ml-auto w-56">
					<Search
						class="absolute top-3.5 left-3 size-4 text-muted-foreground"
					/>
					<Input bind:value={query} placeholder="Search name" class="pl-9" />
				</div>
			</div>
			<div class="rounded-xl border bg-card">
				<Table.Root>
					<Table.Header>
						<Table.Row>
							<Table.Head>Name</Table.Head>
							<Table.Head>State</Table.Head>
							<Table.Head class="hidden md:table-cell">From</Table.Head>
							<Table.Head class="hidden lg:table-cell"
								>Last Intake Email</Table.Head
							>
							<Table.Head class="w-10"
								><span class="sr-only">Commands</span></Table.Head
							>
						</Table.Row>
					</Table.Header>
					<Table.Body>
						{#each filtered as intake (intake.id)}
							{@const person = proto.person(intake.personId)}
							<Table.Row
								class="cursor-pointer"
								onclick={() => {
									proto.sheetIntakeId = intake.id;
								}}
							>
								<Table.Cell>
									<span class="font-medium"
										>{person.firstName} {person.lastName}</span
									>
									{#if proto.isMinorAt(person, w)}<Baby
											class="ml-1 inline size-3.5 text-violet-700"
											aria-label="Minor"
										/>{/if}
									{#if person.medical}<HeartPulse
											class="ml-1 inline size-3.5 text-destructive"
											aria-label="Medical"
										/>{/if}
								</Table.Cell>
								<Table.Cell><IntakeStateBadge {intake} /></Table.Cell>
								<Table.Cell class="hidden text-muted-foreground md:table-cell"
									>{intake.origin === "fast_track"
										? "Fast-track"
										: `Batch ${intake.batchNo}`}</Table.Cell
								>
								<Table.Cell
									class="hidden text-xs text-muted-foreground lg:table-cell"
									>{lastEmail(intake)}</Table.Cell
								>
								<Table.Cell
									onclick={(event: MouseEvent) => event.stopPropagation()}
								>
									<DropdownMenu.Root>
										<DropdownMenu.Trigger>
											{#snippet child({ props })}<Button
													{...props}
													size="icon-sm"
													variant="ghost"
													aria-label="Commands"><Ellipsis /></Button
												>{/snippet}
										</DropdownMenu.Trigger>
										<DropdownMenu.Content align="end">
											<DropdownMenu.Item
												onSelect={() => {
													proto.sheetIntakeId = intake.id;
												}}>Open Intake</DropdownMenu.Item
											>
											<DropdownMenu.Separator />
											{#if intake.state === "contacted"}
												{#if person.carriedFee?.status === "held"}<DropdownMenu.Item
														onSelect={() => proto.confirm(intake.id)}
														>Confirm (Carried Fee)</DropdownMenu.Item
													>{/if}
												<DropdownMenu.Item
													onSelect={() => proto.decline(intake.id)}
													>Decline</DropdownMenu.Item
												>
											{/if}
											{#if intake.state === "paid" && w.status === "scheduled"}
												<DropdownMenu.Item
													onSelect={() => proto.defer(intake.id)}
													>Defer (keep fee)</DropdownMenu.Item
												>
												<DropdownMenu.Item
													onSelect={() => proto.cancelWithRefund(intake.id)}
													>Cancel with refund</DropdownMenu.Item
												>
											{/if}
											{#if OPEN_STATES.includes(intake.state)}
												<DropdownMenu.Item
													class="text-destructive"
													onSelect={() =>
														(proto.dialog = {
															kind: "withdraw",
															intakeId: intake.id,
														})}>Withdraw…</DropdownMenu.Item
												>
												<DropdownMenu.Separator />
												<DropdownMenu.Item
													onSelect={() => proto.resendLink(intake.id)}
													>Resend link</DropdownMenu.Item
												>
												<DropdownMenu.Item
													onSelect={() => proto.rotateLink(intake.id)}
													>Rotate link</DropdownMenu.Item
												>
											{/if}
											{#if finalised && intake.state === "no_show"}
												<DropdownMenu.Item
													onSelect={() =>
														proto.correctAttendance(intake.id, "attended")}
													>Correct → attended</DropdownMenu.Item
												>
												<DropdownMenu.Item
													onSelect={() =>
														proto.correctAttendance(intake.id, "deferred")}
													>Correct → deferred</DropdownMenu.Item
												>
											{/if}
											{#if finalised && intake.state === "attended"}
												{#if ["invited", "joined"].includes(person.standing)}
													<DropdownMenu.Item disabled
														>Invited — attendance locked</DropdownMenu.Item
													>
												{:else}
													<DropdownMenu.Item
														onSelect={() =>
															proto.correctAttendance(intake.id, "no_show")}
														>Correct → no-show</DropdownMenu.Item
													>
												{/if}
											{/if}
										</DropdownMenu.Content>
									</DropdownMenu.Root>
								</Table.Cell>
							</Table.Row>
						{:else}
							<Table.Row
								><Table.Cell
									colspan={5}
									class="py-8 text-center text-muted-foreground"
									>Nobody here yet.</Table.Cell
								></Table.Row
							>
						{/each}
					</Table.Body>
				</Table.Root>
			</div>
		</Tabs.Content>

		<Tabs.Content value="batches" class="flex flex-col gap-3 pt-3">
			{#each w.batches as batch (batch.no)}
				{@const members = intakes.filter(
					(intake) => intake.batchNo === batch.no,
				)}
				<div class="rounded-xl border bg-card p-4 text-sm">
					<p class="font-semibold">
						Batch {batch.no} · sent {fmtDayTime(batch.sentAt)} by {batch.sentBy}
					</p>
					<p class="text-muted-foreground">
						Window {dayjs(batch.windowEnd).isAfter(NOW) ? "ends" : "ended"}
						{fmtDayTime(batch.windowEnd)} · {members.length} contacted · {members.filter(
							(intake) =>
								["paid", "attended", "no_show"].includes(intake.state),
						).length} paid
					</p>
				</div>
			{/each}
			{#if proposal.length}
				<div
					class="rounded-xl border-2 border-dashed border-secondary bg-secondary/10 p-4"
				>
					<div class="flex flex-wrap items-center justify-between gap-2">
						<p class="font-semibold">
							Proposed Batch {(proto.lastBatch(w)?.no ?? 0) + 1}: {proposal.length}
							people
						</p>
						<Button
							size="sm"
							disabled={phase === "window_open"}
							onclick={() =>
								(proto.dialog = { kind: "send_batch", workshopId: w.id })}
							><Send /> Review and send</Button
						>
					</div>
					<p class="mt-1 text-sm text-muted-foreground">
						{phase === "window_open"
							? "Proposed when the current window ends. "
							: ""}{proposal
							.slice(0, 6)
							.map((person) => person.firstName)
							.join(", ")}{proposal.length > 6
							? ` +${proposal.length - 6}`
							: ""}
					</p>
				</div>
			{/if}
		</Tabs.Content>

		{#if finalised}
			<Tabs.Content value="attended" class="flex flex-col gap-3 pt-3">
				<p class="text-sm text-muted-foreground">
					Follow-up {w.followUpSentAt
						? `sent ${fmtDayTime(w.followUpSentAt)}`
						: "goes out 10:00 tomorrow"}. Invite is one click per person; the
					same action is on the cross-workshop Invitable view.
				</p>
				<ul class="divide-y rounded-xl border bg-card">
					{#each attended as intake (intake.id)}
						{@const person = proto.person(intake.personId)}
						{@const refusal = proto.inviteRefusals[person.id]}
						<li class="flex flex-wrap items-center gap-3 px-4 py-2.5 text-sm">
							<span class="flex-1"
								>{person.firstName}
								{person.lastName}{#if person.invitationNote}<span
										class="block text-xs text-muted-foreground"
										>{person.invitationNote}</span
									>{/if}</span
							>
							{#if refusal}<span class="text-xs text-destructive"
									>Refused: {refusal}</span
								>{/if}
							{#if person.standing === "attended"}
								<Button
									size="sm"
									variant="outline"
									onclick={() => proto.sendInvitation(person.id)}>Invite</Button
								>
							{:else}
								<Badge variant="outline">{person.standing}</Badge>
							{/if}
						</li>
					{/each}
				</ul>
			</Tabs.Content>
		{/if}

		<Tabs.Content value="closed" class="pt-3">
			<ul class="divide-y rounded-xl border bg-card">
				{#each closed as intake (intake.id)}
					{@const person = proto.person(intake.personId)}
					<li>
						<button
							type="button"
							class="flex w-full cursor-pointer items-center gap-3 px-4 py-2.5 text-left text-sm hover:bg-muted/50"
							onclick={() => {
								proto.sheetIntakeId = intake.id;
							}}
						>
							<span class="flex-1">{person.firstName} {person.lastName}</span>
							<IntakeStateBadge {intake} />
							<span class="w-24 text-right text-xs text-muted-foreground"
								>{intake.closedAt ? fmtDay(intake.closedAt) : ""}</span
							>
						</button>
					</li>
				{:else}
					<li class="px-4 py-6 text-center text-sm text-muted-foreground">
						No closed Intakes.
					</li>
				{/each}
			</ul>
		</Tabs.Content>
	</Tabs.Root>
</div>
