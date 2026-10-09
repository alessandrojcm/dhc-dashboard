<!-- PROTOTYPE — throwaway (ALE-372). The body of one command dialog. Keyed on the request
     by command-dialogs.svelte, so its form state starts fresh for every dialog. -->
<script lang="ts">
import { parseDate } from "@internationalized/date";
import { AlertTriangle, Baby, Search } from "@lucide/svelte";
import dayjs from "dayjs";
import { untrack } from "svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Checkbox } from "#lib/components/ui/checkbox/index.js";
import DatePicker from "#lib/components/ui/date-picker.svelte";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import type { DialogRequest } from "./bw-prototype-store.svelte";
import { Input } from "#lib/components/ui/input/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import * as NativeSelect from "#lib/components/ui/native-select/index.js";
import * as RadioGroup from "#lib/components/ui/radio-group/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import {
	euro,
	fmtDay,
	fmtDayLong,
	fmtDayTime,
	NOW,
	OPEN_STATES,
	proto,
	STAFF,
} from "./bw-prototype-store.svelte";

let { request }: { request: DialogRequest } = $props();
const w = $derived(
	"workshopId" in request ? proto.workshop(request.workshopId) : undefined,
);

function close() {
	proto.dialog = null;
}
function done(result: { ok: boolean }) {
	if (result.ok) close();
}

// --- form state: initialised once per request ---------------------------------
function initialForm(current: DialogRequest) {
	const ws =
		"workshopId" in current ? proto.workshop(current.workshopId) : undefined;
	const proposedEnd = NOW.add(7, "day");
	const cutoff = ws ? dayjs(ws.paymentCutoff) : undefined;
	return {
		date: ws?.date ?? "2026-12-05",
		time: ws?.startTime ?? "11:00",
		venue: ws?.venue ?? "Pearse Street Community Hall, Dublin 2",
		capacity: ws?.capacity ?? 16,
		fee: ws ? ws.fee / 100 : 65,
		cutoffDate: cutoff?.format("YYYY-MM-DD") ?? "",
		cutoffTime: cutoff?.format("HH:mm") ?? "11:00",
		coachId: ws?.coachId ?? "",
		assistantIds: ws ? [...ws.assistantIds] : [],
		windowDate: (cutoff && proposedEnd.isAfter(cutoff)
			? cutoff
			: proposedEnd
		).format("YYYY-MM-DD"),
		windowTime:
			cutoff && proposedEnd.isAfter(cutoff) ? cutoff.format("HH:mm") : "23:59",
	};
}
const init = untrack(() => initialForm(request));
let date = $state(init.date);
let time = $state(init.time);
let venue = $state(init.venue);
let capacity = $state(init.capacity);
let fee = $state(init.fee);
let cutoffDays = $state(3);
let cutoffDate = $state(init.cutoffDate);
let cutoffTime = $state(init.cutoffTime);
let coachId = $state(init.coachId);
let assistantIds = $state<string[]>(init.assistantIds);
let windowDate = $state(init.windowDate);
let windowTime = $state(init.windowTime);
let note = $state("");
let refund = $state("refund");
let query = $state("");
let newPerson = $state({ firstName: "", lastName: "", email: "", dob: "" });
let addingNew = $state(false);
let newPersonRefusal = $state<string | null>(null);

const proposal = $derived(w ? proto.proposal(w) : []);
const windowEnd = $derived(`${windowDate}T${windowTime}:00`);
const windowPastCutoff = $derived(
	w ? dayjs(windowEnd).isAfter(w.paymentCutoff) : false,
);

const fastTrackCandidates = $derived.by(() => {
	if (!w || request.kind !== "fast_track") return [];
	const needle = query.trim().toLowerCase();
	return proto.people
		.filter((person) => {
			if (proto.openIntakeOf(person.id)) return false;
			if (
				person.standing === "removed" &&
				dayjs(person.removedAt).add(3, "month").isBefore(NOW)
			)
				return false;
			if (!["waiting", "removed"].includes(person.standing)) return false;
			if (proto.afterCutoff(w) && person.carriedFee?.status !== "held")
				return false;
			return (
				!needle ||
				`${person.firstName} ${person.lastName} ${person.email}`
					.toLowerCase()
					.includes(needle)
			);
		})
		.sort((a, b) => a.registeredAt.localeCompare(b.registeredAt))
		.slice(0, 8);
});

const cancelSummary = $derived.by(() => {
	if (!w) return { paid: 0, contacted: 0, holds: 0 };
	const list = proto.intakesOf(w.id);
	return {
		paid: list.filter((intake) => intake.state === "paid").length,
		contacted: list.filter((intake) => intake.state === "contacted").length,
		holds: list.filter((intake) => proto.holdLive(intake)).length,
	};
});
const openCount = $derived(
	w
		? proto
				.intakesOf(w.id)
				.filter((intake) => OPEN_STATES.includes(intake.state)).length
		: 0,
);
const willNoShow = $derived(
	w
		? proto
				.intakesOf(w.id)
				.filter((intake) => intake.state === "paid" && !intake.checkedIn)
		: [],
);
const withdrawIntake = $derived(
	request.kind === "withdraw" ? proto.intake(request.intakeId) : undefined,
);
const withdrawPerson = $derived(
	withdrawIntake ? proto.person(withdrawIntake.personId) : undefined,
);
const needsRefundChoice = $derived(
	withdrawIntake?.state === "paid" ||
		(withdrawPerson?.carriedFee &&
			["held", "applied"].includes(withdrawPerson.carriedFee.status)),
);

function rescheduleCutoffFollows(nextDate: string) {
	if (!w) return;
	const offset = dayjs(`${w.date}T${w.startTime}:00`).diff(
		dayjs(w.paymentCutoff),
		"minute",
	);
	const cutoff = dayjs(`${nextDate}T${time}:00`).subtract(offset, "minute");
	cutoffDate = cutoff.format("YYYY-MM-DD");
	cutoffTime = cutoff.format("HH:mm");
}
</script>

{#snippet staffFields()}
	<div class="grid gap-2">
		<Label for="bw-coach">Coach</Label>
		<NativeSelect.Root id="bw-coach" bind:value={coachId} class="w-full">
			<NativeSelect.Option value=""
				>No coach yet (Unstaffed)</NativeSelect.Option
			>
			{#each STAFF.filter((member) => member.isCoach) as member (member.id)}
				<NativeSelect.Option value={member.id}
					>{member.name}</NativeSelect.Option
				>
			{/each}
		</NativeSelect.Root>
	</div>
	<fieldset class="grid gap-2">
		<legend class="mb-1 text-sm font-medium"
			>Assistants <span class="text-muted-foreground">(any active Member)</span
			></legend
		>
		{#each STAFF.filter((member) => member.id !== coachId) as member (member.id)}
			<label class="flex items-center gap-2 text-sm">
				<Checkbox
					checked={assistantIds.includes(member.id)}
					onCheckedChange={(checked) =>
						(assistantIds = checked
							? [...assistantIds, member.id]
							: assistantIds.filter((id) => id !== member.id))}
				/>
				{member.name}{member.isCoach ? " (coach)" : ""}
			</label>
		{/each}
	</fieldset>
{/snippet}

{#if request.kind === "schedule"}
	<Dialog.Header>
		<Dialog.Title>Schedule a Beginners' Workshop</Dialog.Title>
		<Dialog.Description
			>Staff are optional now; you can assign them until attendance is
			finalised.</Dialog.Description
		>
	</Dialog.Header>
	<div class="grid gap-4">
		<div class="grid grid-cols-[1fr_8rem] gap-3">
			<div class="grid gap-2">
				<Label>Date</Label><DatePicker
					value={parseDate(date)}
					onValueChange={(value) => value && (date = value.toString())}
				/>
			</div>
			<div class="grid gap-2">
				<Label for="bw-time">Start</Label><Input
					id="bw-time"
					type="time"
					bind:value={time}
				/>
			</div>
		</div>
		<div class="grid gap-2">
			<Label for="bw-venue">Venue</Label><Input
				id="bw-venue"
				bind:value={venue}
			/>
		</div>
		<div class="grid grid-cols-3 gap-3">
			<div class="grid gap-2">
				<Label for="bw-cap">Capacity</Label><Input
					id="bw-cap"
					type="number"
					min="1"
					bind:value={capacity}
				/>
			</div>
			<div class="grid gap-2">
				<Label for="bw-fee">Fee (€)</Label><Input
					id="bw-fee"
					type="number"
					min="0"
					bind:value={fee}
				/>
			</div>
			<div class="grid gap-2">
				<Label for="bw-cut">Cutoff (days before)</Label><Input
					id="bw-cut"
					type="number"
					min="0"
					bind:value={cutoffDays}
				/>
			</div>
		</div>
		<p class="text-xs text-muted-foreground">
			Payment Cutoff: {fmtDayTime(
				dayjs(`${date}T${time}:00`).subtract(cutoffDays, "day"),
			)}. The fee locks once the first Intake exists.
		</p>
		{@render staffFields()}
	</div>
	<Dialog.Footer>
		<Button variant="outline" onclick={close}>Cancel</Button>
		<Button
			onclick={() => {
				proto.schedule({
					date,
					startTime: time,
					venue,
					capacity,
					fee: fee * 100,
					cutoffDays,
					coachId: coachId || undefined,
					assistantIds,
				});
				close();
			}}>Schedule</Button
		>
	</Dialog.Footer>
{:else if request.kind === "send_batch" && w}
	<Dialog.Header>
		<Dialog.Title>Send Batch {(proto.lastBatch(w)?.no ?? 0) + 1}</Dialog.Title>
		<Dialog.Description>
			{proposal.length} seats = capacity {w.capacity} − {proto.seats(w).paid} paid.
			Drafted in Waitlist priority order when you press Send; anyone another workshop
			contacts first is skipped.
		</Dialog.Description>
	</Dialog.Header>
	<div class="grid gap-4">
		<ol class="max-h-56 divide-y overflow-y-auto rounded-lg border text-sm">
			{#each proposal as person, index (person.id)}
				<li class="flex items-center gap-2 px-3 py-1.5">
					<span
						class="w-5 text-right text-xs text-muted-foreground tabular-nums"
						>{index + 1}</span
					>
					<span class="flex-1">{person.firstName} {person.lastName}</span>
					{#if person.carriedFee?.status === "held"}<Badge
							variant="outline"
							class="border-secondary">Carried Fee · confirms</Badge
						>{/if}
					{#if proto.isMinorAt(person, w)}<Badge
							variant="outline"
							class="border-violet-600 text-violet-800"><Baby /> Minor</Badge
						>{/if}
					<span class="text-xs text-muted-foreground"
						>since {dayjs(person.registeredAt).format("MMM YYYY")}</span
					>
				</li>
			{/each}
		</ol>
		<div class="grid gap-2">
			<Label>Payment window ends</Label>
			<div class="grid grid-cols-[1fr_7rem] gap-3">
				<DatePicker
					value={parseDate(windowDate)}
					maxValue={parseDate(dayjs(w.paymentCutoff).format("YYYY-MM-DD"))}
					minValue={parseDate(NOW.format("YYYY-MM-DD"))}
					onValueChange={(value) => value && (windowDate = value.toString())}
				/>
				<Input
					type="time"
					bind:value={windowTime}
					aria-label="Window end time"
				/>
			</div>
			<p
				class="text-xs {windowPastCutoff
					? 'text-destructive'
					: 'text-muted-foreground'}"
			>
				Default 7 days; never past the Payment Cutoff ({fmtDayTime(
					w.paymentCutoff,
				)}). After the window ends, unpaid people can still pay while seats
				remain, and the next Batch is proposed.
			</p>
		</div>
	</div>
	<Dialog.Footer>
		<Button variant="outline" onclick={close}>Cancel</Button>
		<Button
			disabled={windowPastCutoff || !proposal.length}
			onclick={() => done(proto.sendBatch(w.id, windowEnd))}
			>Send to {proposal.length} people</Button
		>
	</Dialog.Footer>
{:else if request.kind === "fast_track" && w}
	<Dialog.Header>
		<Dialog.Title>Fast-track into {fmtDay(w.date)}</Dialog.Title>
		<Dialog.Description>
			{proto.afterCutoff(w)
				? "Payment is closed, so only Carried Fee holders can be fast-tracked (they confirm instead of paying)."
				: "Outside Batch order. They're contacted and pay like anyone else; seats go to whoever pays first."}
		</Dialog.Description>
	</Dialog.Header>
	{#if !addingNew}
		<div class="grid gap-3">
			<div class="relative">
				<Search class="absolute top-3.5 left-3 size-4 text-muted-foreground" />
				<Input
					bind:value={query}
					placeholder="Search Waitlist (waiting, or removed in the last 3 months)"
					class="pl-9"
				/>
			</div>
			<ul class="divide-y rounded-lg border text-sm">
				{#each fastTrackCandidates as person (person.id)}
					<li class="flex items-center gap-2 px-3 py-2">
						<span class="flex-1"
							>{person.firstName}
							{person.lastName}<span class="block text-xs text-muted-foreground"
								>{person.email}</span
							></span
						>
						{#if person.standing === "removed"}<Badge variant="outline"
								>removed · restores</Badge
							>{/if}
						{#if person.carriedFee?.status === "held"}<Badge
								variant="outline"
								class="border-secondary">Carried Fee</Badge
							>{/if}
						<Button
							size="sm"
							variant="outline"
							onclick={() => done(proto.fastTrack(w.id, person.id, note))}
							>Fast-track</Button
						>
					</li>
				{:else}
					<li class="px-3 py-4 text-center text-muted-foreground">
						No one matches.
					</li>
				{/each}
			</ul>
			<Textarea
				bind:value={note}
				rows={2}
				placeholder="Why (optional), e.g. “Coach's colleague, asked in person”"
			/>
		</div>
		<Dialog.Footer>
			<Button
				variant="ghost"
				disabled={proto.afterCutoff(w)}
				onclick={() => (addingNew = true)}>Not on the Waitlist? Add them</Button
			>
		</Dialog.Footer>
	{:else}
		<div class="grid gap-3">
			<p class="text-xs text-muted-foreground">
				Staff-only registration: works even when the public Waitlist is closed.
				Priority = today.
			</p>
			<div class="grid grid-cols-2 gap-3">
				<div class="grid gap-2">
					<Label for="np-f">First name</Label><Input
						id="np-f"
						bind:value={newPerson.firstName}
					/>
				</div>
				<div class="grid gap-2">
					<Label for="np-l">Last name</Label><Input
						id="np-l"
						bind:value={newPerson.lastName}
					/>
				</div>
			</div>
			<div class="grid gap-2">
				<Label for="np-e">Email</Label>
				<Input
					id="np-e"
					type="email"
					bind:value={newPerson.email}
					aria-invalid={newPersonRefusal !== null}
					oninput={() => (newPersonRefusal = null)}
				/>
				{#if newPersonRefusal}
					<p class="text-xs text-destructive">
						Refused {newPersonRefusal}: {newPersonRefusal ===
						":email_belongs_to_member"
							? "this email belongs to a Member or former Member."
							: newPersonRefusal === ":pending_invitation"
								? "this email already has a pending Invitation."
								: "this email is already on the Waitlist — search for them instead."}
					</p>
				{:else}
					<p class="text-xs text-muted-foreground">
						Try ciaran.walsh@example.ie (Member) or jo.direct@example.ie
						(pending Invitation).
					</p>
				{/if}
			</div>
			<div class="grid gap-2">
				<Label>Date of birth</Label><DatePicker
					value={newPerson.dob ? parseDate(newPerson.dob) : undefined}
					onValueChange={(value) => {
						if (value) newPerson.dob = value.toString();
					}}
				/>
			</div>
			<p class="text-xs text-muted-foreground">
				…plus the rest of the public registration form (pronouns, phone,
				medical, guardian for under-18s).
			</p>
		</div>
		<Dialog.Footer>
			<Button variant="outline" onclick={() => (addingNew = false)}>Back</Button
			>
			<Button
				disabled={!newPerson.firstName || !newPerson.email}
				onclick={() => {
					const result = proto.addPersonAndFastTrack(w.id, newPerson);
					if (result.ok) close();
					else newPersonRefusal = result.reason;
				}}>Add and fast-track</Button
			>
		</Dialog.Footer>
	{/if}
{:else if request.kind === "staff" && w}
	<Dialog.Header>
		<Dialog.Title>Staff for {fmtDay(w.date)}</Dialog.Title>
		<Dialog.Description
			>Access changes immediately. Staff see the roster and check people in;
			nothing else. Emails never name the coach, so changes email no attendee.</Dialog.Description
		>
	</Dialog.Header>
	<div class="grid gap-4">{@render staffFields()}</div>
	<Dialog.Footer>
		<Button variant="outline" onclick={close}>Cancel</Button>
		<Button
			onclick={() =>
				done(proto.setStaff(w.id, coachId || undefined, assistantIds))}
			>Save staff</Button
		>
	</Dialog.Footer>
{:else if request.kind === "settings" && w}
	<Dialog.Header>
		<Dialog.Title>Capacity, fee and Payment Cutoff</Dialog.Title>
		<Dialog.Description
			>Changing these emails nobody and sends no top-up Batch.</Dialog.Description
		>
	</Dialog.Header>
	<div class="grid gap-4">
		<div class="grid grid-cols-2 gap-3">
			<div class="grid gap-2">
				<Label for="st-cap">Capacity</Label><Input
					id="st-cap"
					type="number"
					bind:value={capacity}
				/><span class="text-xs text-muted-foreground"
					>Not below {proto.seats(w).paid + proto.seats(w).holds} taken</span
				>
			</div>
			<div class="grid gap-2">
				<Label for="st-fee">Fee (€)</Label><Input
					id="st-fee"
					type="number"
					bind:value={fee}
					disabled={proto.intakesOf(w.id).length > 0}
				/><span class="text-xs text-muted-foreground"
					>{proto.intakesOf(w.id).length
						? "Locked: Intakes exist"
						: "Editable until the first Intake"}</span
				>
			</div>
		</div>
		<div class="grid gap-2">
			<Label>Payment Cutoff</Label>
			<div class="grid grid-cols-[1fr_7rem] gap-3">
				<DatePicker
					value={parseDate(cutoffDate)}
					onValueChange={(value) => value && (cutoffDate = value.toString())}
				/>
				<Input type="time" bind:value={cutoffTime} aria-label="Cutoff time" />
			</div>
		</div>
	</div>
	<Dialog.Footer>
		<Button variant="outline" onclick={close}>Cancel</Button>
		<Button
			onclick={() =>
				done(
					proto.updateSettings(w.id, {
						capacity,
						fee: fee * 100,
						paymentCutoff: `${cutoffDate}T${cutoffTime}:00`,
					}),
				)}>Save</Button
		>
	</Dialog.Footer>
{:else if request.kind === "reschedule" && w}
	<Dialog.Header>
		<Dialog.Title>Reschedule {fmtDay(w.date)}</Dialog.Title>
		<Dialog.Description
			>Same workshop: every Intake carries on, nobody reconfirms. Anyone who
			can't make it replies, and you defer or refund them.</Dialog.Description
		>
	</Dialog.Header>
	<div class="grid gap-4">
		<div class="grid grid-cols-[1fr_7rem] gap-3">
			<div class="grid gap-2">
				<Label>New date</Label><DatePicker
					value={parseDate(date)}
					onValueChange={(value) => {
						if (value) {
							date = value.toString();
							rescheduleCutoffFollows(date);
						}
					}}
				/>
			</div>
			<div class="grid gap-2">
				<Label for="rs-time">Start</Label><Input
					id="rs-time"
					type="time"
					bind:value={time}
				/>
			</div>
		</div>
		<div class="grid gap-2">
			<Label for="rs-venue">Venue</Label><Input
				id="rs-venue"
				bind:value={venue}
			/>
		</div>
		<div class="grid gap-2">
			<Label
				>Payment Cutoff <span class="font-normal text-muted-foreground"
					>(keeps its offset; editable)</span
				></Label
			>
			<div class="grid grid-cols-[1fr_7rem] gap-3">
				<DatePicker
					value={parseDate(cutoffDate)}
					onValueChange={(value) => value && (cutoffDate = value.toString())}
				/>
				<Input type="time" bind:value={cutoffTime} aria-label="Cutoff time" />
			</div>
		</div>
		<p
			class="flex items-center gap-2 rounded-lg border border-amber-500 bg-amber-50 p-2.5 text-sm text-amber-900"
		>
			<AlertTriangle class="size-4 shrink-0" /> This emails {openCount} people “Workshop
			rescheduled”.
		</p>
	</div>
	<Dialog.Footer>
		<Button variant="outline" onclick={close}>Keep current date</Button>
		<Button
			onclick={() =>
				done(
					proto.reschedule(w.id, {
						date,
						startTime: time,
						venue,
						paymentCutoff: `${cutoffDate}T${cutoffTime}:00`,
					}),
				)}>Reschedule and email {openCount}</Button
		>
	</Dialog.Footer>
{:else if request.kind === "cancel_workshop" && w}
	<Dialog.Header>
		<Dialog.Title>Cancel {fmtDayLong(w.date)}?</Dialog.Title>
		<Dialog.Description
			>This can't be undone. The workshop stays visible, read-only.</Dialog.Description
		>
	</Dialog.Header>
	<ul class="grid gap-1.5 text-sm">
		<li>
			• <strong>{cancelSummary.paid}</strong> paid → deferred; the fee becomes a Carried
			Fee. Email: “Workshop cancelled — paid” (asks refund or keep).
		</li>
		<li>
			• <strong>{cancelSummary.contacted}</strong> contacted → back to the Waitlist
			with their original date. Email: “Workshop cancelled — unpaid”.
		</li>
		{#if cancelSummary.holds}<li>
				• <strong>{cancelSummary.holds}</strong> live Seat Holds released; a payment
				that lands anyway is refunded automatically.
			</li>{/if}
		<li>• Assigned staff get an in-app Notification.</li>
	</ul>
	<Textarea
		bind:value={note}
		rows={2}
		placeholder="Reason, kept with each Intake (optional)"
	/>
	<Dialog.Footer>
		<Button variant="outline" onclick={close}>Keep workshop</Button>
		<Button
			variant="destructive"
			onclick={() => done(proto.cancelWorkshop(w.id, note))}
			>Cancel and email {cancelSummary.paid + cancelSummary.contacted}</Button
		>
	</Dialog.Footer>
{:else if request.kind === "finish" && w}
	<Dialog.Header>
		<Dialog.Title>Finish workshop?</Dialog.Title>
		<Dialog.Description
			>Closes check-in and freezes staff. Afterwards only a coordinator can
			correct attendance, one person at a time.</Dialog.Description
		>
	</Dialog.Header>
	{#if willNoShow.length}
		<div class="grid gap-1.5 text-sm">
			<p>
				<strong>{willNoShow.length}</strong> not checked in will become
				<strong>no-show</strong> (fee kept, removed from the Waitlist):
			</p>
			<ul class="flex flex-wrap gap-1.5">
				{#each willNoShow as intake (intake.id)}
					<li>
						<Badge variant="outline" class="border-destructive text-destructive"
							>{proto.person(intake.personId).firstName}
							{proto.person(intake.personId).lastName}</Badge
						>
					</li>
				{/each}
			</ul>
		</div>
	{:else}
		<p class="text-sm">Everyone is checked in.</p>
	{/if}
	<Dialog.Footer>
		<Button variant="outline" onclick={close}>Not yet</Button>
		<Button onclick={() => done(proto.finish(w.id))}>Finish workshop</Button>
	</Dialog.Footer>
{:else if request.kind === "withdraw" && withdrawIntake && withdrawPerson}
	<Dialog.Header>
		<Dialog.Title
			>Withdraw {withdrawPerson.firstName} from the Waitlist</Dialog.Title
		>
		<Dialog.Description
			>Leaves the Waitlist entirely (restorable for 3 months). Never carries a
			fee over.</Dialog.Description
		>
	</Dialog.Header>
	{#if needsRefundChoice}
		<RadioGroup.Root bind:value={refund} class="gap-2">
			<label class="flex items-start gap-2 rounded-lg border p-3 text-sm">
				<RadioGroup.Item value="refund" class="mt-0.5" />
				<span
					><strong
						>Refund {euro(
							withdrawPerson.carriedFee?.amount ??
								proto.workshop(withdrawIntake.workshopId).fee,
						)}</strong
					><span class="block text-muted-foreground"
						>Full amount against the original payment. Email: “Withdrawn —
						refunded”.</span
					></span
				>
			</label>
			<label class="flex items-start gap-2 rounded-lg border p-3 text-sm">
				<RadioGroup.Item value="forfeit" class="mt-0.5" />
				<span
					><strong>Forfeit the fee</strong><span
						class="block text-muted-foreground"
						>Email: “Withdrawn — forfeited”.</span
					></span
				>
			</label>
		</RadioGroup.Root>
	{:else}
		<p class="text-sm">Not paid: their Intake closes as declined.</p>
	{/if}
	<Textarea bind:value={note} rows={2} placeholder="Note (optional)" />
	<Dialog.Footer>
		<Button variant="outline" onclick={close}>Cancel</Button>
		<Button
			variant="destructive"
			onclick={() =>
				done(proto.withdraw(withdrawIntake.id, refund === "refund", note))}
			>Withdraw</Button
		>
	</Dialog.Footer>
{/if}
