<!--
	ALE-380: the coordinator console of one Beginners' Workshop — the
	lifecycle timeline, the "Now" card, Needs attention, the Next Batch
	preview with Pause/Resume beside it, and the roster grouped by meaning
	(ALE-391: Attended / No-show / Out once attendance is final, when the
	workshop is read-only).
	Everything shown is Phoenix's console read model. Pause/Resume and
	(ALE-384) Fast-track and (ALE-394) Reschedule are its commands; Batches
	themselves come only from the system sweep. (ALE-382) Failed refunds sit
	under Needs attention with Retry and Record manual refund, and each roster
	row shows its refund. (ALE-392) Once attendance is final, each attended
	person who is still Invitable has an Invite button (for `members.invite`
	holders), the rest show Invited / Joined, and the Now card reads
	"N attended · N invited · N joined".
	row shows its refund. (ALE-386) Each roster row opens its Intake — facts,
	email log, history and only the commands Phoenix lists in
	`availableCommands` — and Needs attention lists contacted people still
	unpaid after their window. (ALE-395) Cancel opens a dialog with what it
	would do; a cancelled workshop stays read-only, its timeline struck
	through, with who cancelled it, the reason and where to go next.
-->
<script lang="ts">
import type {
	BeginnersWorkshopConsole,
	BeginnersWorkshopStaffCandidate,
} from "@dhc/api-client";
import {
	AlertTriangle,
	ArrowLeft,
	Ban,
	CalendarClock,
	CalendarDays,
	MapPin,
	Users,
	Check,
	Circle,
	CircleDot,
	DoorOpen,
	Pause,
	Play,
	Settings,
	UserPlus,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { resolve } from "$app/paths";
import {
	consoleTimeline,
	holdLabel,
	intakeOrigin,
	intakeStateLabel,
	invitationSummary,
	nextBatchHeadline,
	nextBatchSize,
	nowCard,
	personName,
	refundLabel,
	rosterGroups,
	carriedFeeLabel,
	unconfirmedCarriedFeeText,
	standingLabel,
	type TimelineStep,
	unpaidAfterWindowText,
} from "#lib/beginners-workshops/console.js";
import {
	formatCivilDate,
	formatDublinInstant,
	formatDublinTime,
} from "#lib/club-calendar.js";
import {
	formatFee,
	staffSummary,
} from "#lib/beginners-workshops/presentation.js";
import { rescheduleRecipients } from "#lib/beginners-workshops/reschedule.js";
import WorkshopAlerts from "#lib/components/beginners-workshops/workshop-alerts.svelte";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import * as Sheet from "#lib/components/ui/sheet/index.js";
import { cn } from "#lib/utils.js";
import InviteButton from "../../invite-button.svelte";
import SeatMeter from "../../seat-meter.svelte";
import { pauseBatches, resumeBatches } from "./console.remote";
import FailedRefundItem from "./failed-refund-item.svelte";
import FastTrackDialog from "./fast-track-dialog.svelte";
import IntakeDetail from "./intake-detail.svelte";
import RescheduleDialog from "./reschedule-dialog.svelte";
import CancelWorkshopDialog from "./cancel-workshop-dialog.svelte";
import StaffDialog from "../../staff-dialog.svelte";
import WorkshopSettingsDialog from "../../workshop-settings-dialog.svelte";

let {
	view,
	genders = [],
	canInvite = false,
	staffCandidates = [],
}: {
	view: BeginnersWorkshopConsole;
	genders?: string[];
	canInvite?: boolean;
	staffCandidates?: BeginnersWorkshopStaffCandidate[];
} = $props();

let fastTrackDialogOpen = $state(false);
// The Intake open in the side sheet; read from `view`, so it refreshes
// with the console after a command.
let selectedIntakeId = $state<string | null>(null);
const selectedIntake = $derived(
	Object.values(view.roster)
		.flat()
		.find((intake) => intake.id === selectedIntakeId),
);
let rescheduleOpen = $state(false);
let cancelOpen = $state(false);
let staffOpen = $state(false);
let settingsOpen = $state(false);
// Mounted on first open, so the console renders without a search query.
let fastTrackMounted = $state(false);

const workshop = $derived(view.workshop);
const next = $derived(view.nextBatch);
const steps = $derived(consoleTimeline(view));
const now = $derived(nowCard(view));
const groups = $derived(rosterGroups(view));
const scheduled = $derived(workshop.status === "scheduled");
const command = $derived(
	view.pause.paused
		? resumeBatches.for(workshop.id)
		: pauseBatches.for(workshop.id),
);
const attention = $derived(
	view.attention.map(
		() =>
			"Places are available, but nobody is waiting. Automatic offers will resume when someone joins the waitlist.",
	),
);
// One amber look for every Needs attention item, button or callout.
const attentionClass =
	"rounded-xl border-2 border-amber-500 bg-amber-50 p-3 text-foreground";
</script>

{#snippet attentionPerson(intakeId: string, text: string, testId: string)}
	<Button
		variant="outline"
		class={cn(
			attentionClass,
			"h-auto justify-start gap-3 text-left font-normal whitespace-normal shadow-none hover:border-amber-600 hover:bg-amber-100",
		)}
		data-testid={testId}
		onclick={() => (selectedIntakeId = intakeId)}
	>
		<AlertTriangle /><span>{text}</span>
	</Button>
{/snippet}

{#snippet stepIcon(state: TimelineStep["state"])}
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

<div class="space-y-6 py-5 sm:py-8">
	<header class="space-y-4 border-b border-border/80 pb-6">
		<Button
			variant="ghost"
			class="w-fit"
			href="/dashboard/beginners-workshop/workshops"
		>
			<ArrowLeft /> Beginners' Workshops
		</Button>
		<div class="flex flex-wrap items-start justify-between gap-4">
			<div class="space-y-3">
				<p class="text-xs font-bold tracking-[0.18em] text-primary uppercase">
					Beginners' Workshop · Manage workshop
				</p>
				<h1 class="font-heading text-3xl leading-tight sm:text-4xl">
					{formatCivilDate(workshop.date)}
				</h1>
				<div
					class="flex flex-wrap gap-x-5 gap-y-2 text-sm text-muted-foreground"
				>
					<p class="flex items-center gap-2">
						<CalendarDays
							class="size-4 text-primary"
							aria-hidden="true"
						/>{workshop.startTime}
					</p>
					<p class="flex items-center gap-2">
						<MapPin
							class="size-4 text-primary"
							aria-hidden="true"
						/>{workshop.venue}
					</p>
					<p class="flex items-center gap-2" data-testid="console-staff">
						<Users
							class="size-4 text-primary"
							aria-hidden="true"
						/>{staffSummary(workshop.staff)}
					</p>
				</div>
			</div>
			<div class="flex flex-wrap gap-2">
				{#if scheduled}
					<Button
						type="button"
						variant="outline"
						onclick={() => (settingsOpen = true)}
					>
						<Settings /> Settings
					</Button>
					<Button
						type="button"
						variant="outline"
						onclick={() => (staffOpen = true)}
					>
						<Users />
						{workshop.staff.coach || workshop.staff.assistants.length
							? "Manage staff"
							: "Add staff"}
					</Button>
					<Button
						type="button"
						variant="outline"
						class="w-fit"
						onclick={() => (rescheduleOpen = true)}
					>
						<CalendarClock /> Reschedule
					</Button>
					{#if view.cancelPreview}
						<Button
							type="button"
							variant="outline"
							class="w-fit border-destructive text-destructive"
							onclick={() => (cancelOpen = true)}
						>
							<Ban /> Cancel workshop
						</Button>
					{/if}
				{/if}
			</div>
		</div>
		{#if view.cancellation?.reason}
			<p class="text-sm" data-testid="cancel-reason">
				<span class="font-semibold">Reason:</span>
				{view.cancellation.reason}
			</p>
		{/if}
	</header>
	<section
		aria-label="Workshop details"
		class="rounded-2xl border bg-field p-5 sm:p-6"
	>
		<h2 class="font-heading text-xl">Workshop details</h2>
		<dl class="mt-4 grid gap-5 sm:grid-cols-2 xl:grid-cols-4">
			<div class="space-y-2">
				<dt class="text-sm text-muted-foreground">Workshop places</dt>
				<dd>
					<SeatMeter
						seats={workshop.seats}
						finalised={workshop.status === "finalised"}
					/>
				</dd>
				<dd class="text-sm text-muted-foreground">
					{formatFee(workshop.feeCents)} per person
				</dd>
			</div>
			<div class="space-y-2">
				<dt class="text-sm text-muted-foreground">Offer-round size</dt>
				<dd class="text-lg font-semibold">
					{#if scheduled && next.status !== "closed"}Up to {next.size} people in the
						next round{:else}No further rounds planned{/if}
				</dd>
				<dd class="text-sm text-muted-foreground">
					Workshop capacity minus people already paid.
				</dd>
			</div>
			<div class="space-y-2">
				<dt class="text-sm text-muted-foreground">Next offer emails</dt>
				<dd class="font-semibold">
					{scheduled ? nextBatchHeadline(next) : "No more automatic offers"}
				</dd>
				<dd class="text-sm text-muted-foreground">
					Offers start {formatCivilDate(workshop.contactFromDate)}.
				</dd>
			</div>
			<div class="space-y-2">
				<dt class="text-sm text-muted-foreground">Payment deadline</dt>
				<dd class="font-semibold">
					{formatDublinInstant(workshop.paymentCutoff)}
				</dd>
				<dd class="text-sm text-muted-foreground">
					{workshop.paymentWindowDays}-day reply window, ending sooner if it
					reaches the payment deadline.
				</dd>
			</div>
		</dl>
	</section>
	<div class="grid items-start gap-6 lg:grid-cols-[20rem_minmax(0,1fr)]">
		<aside
			class="min-w-0 space-y-5 rounded-2xl border border-border bg-card p-5"
		>
			<div class="space-y-1">
				<h2 class="font-heading text-xl">Workshop timeline</h2>
				<p class="text-sm text-muted-foreground">
					From first contact to Follow-up.
				</p>
			</div>
			<ol class="lifecycle" aria-label="Lifecycle">
				{#each steps as step, index (index)}
					<li
						class={cn(
							"timeline-step rounded-lg",
							step.state === "now" &&
								"bg-secondary/15 ring-1 ring-inset ring-secondary/50",
							step.state === "skipped" && "opacity-40 line-through",
						)}
						data-state={step.state}
					>
						<span
							class="timeline-marker rounded-full border border-border bg-card"
							>{@render stepIcon(step.state)}</span
						>
						<div class="min-w-0 pt-1">
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
						</div>
					</li>
				{/each}
			</ol>
		</aside>

		<div class="flex min-w-0 flex-col gap-5">
			<section
				class="flex flex-col gap-3 rounded-2xl border-2 border-primary bg-primary/5 p-6 shadow-[4px_4px_0_var(--color-secondary)]"
				aria-label="Now"
			>
				<p
					class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
				>
					Now
				</p>
				<h2 class="font-heading text-2xl leading-tight">{now.title}</h2>
				<p class="max-w-3xl text-sm leading-6 text-muted-foreground">
					{now.body}
				</p>
				{#if view.finalisation}
					<p class="text-sm font-semibold" data-testid="invitation-summary">
						{invitationSummary(view.finalisation.invitations)}
					</p>
				{/if}
				{#if workshop.stage === "today_before_check_in" || workshop.stage === "check_in_open" || workshop.stage === "awaiting_finalisation"}
					<Button
						class="w-fit"
						href={resolve(
							"/dashboard/beginners-workshop/workshops/[workshopId]/door",
							{ workshopId: workshop.id },
						)}
					>
						<DoorOpen /> Open check-in
					</Button>
				{/if}
			</section>

			{#if attention.length || workshop.alerts.length || view.failedRefunds.length || view.unpaidAfterWindow.length || view.unconfirmedCarriedFees.length}
				<section
					class="flex flex-col gap-3 rounded-2xl border border-amber-500/50 bg-amber-50/50 p-5"
					aria-labelledby="bw-attention"
				>
					<h2
						id="bw-attention"
						class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
					>
						Needs attention
					</h2>
					{#if workshop.alerts.length}
						<div class="flex flex-wrap gap-2">
							<WorkshopAlerts alerts={workshop.alerts} />
						</div>
					{/if}
					{#each view.failedRefunds as refund (refund.id)}
						<FailedRefundItem workshopId={workshop.id} {refund} />
					{/each}
					{#each view.unpaidAfterWindow as person (person.id)}
						{@render attentionPerson(
							person.id,
							unpaidAfterWindowText(person),
							"unpaid-after-window",
						)}
					{/each}
					{#each view.unconfirmedCarriedFees as person (person.id)}
						{@render attentionPerson(
							person.id,
							unconfirmedCarriedFeeText(person),
							"unconfirmed-carried-fee",
						)}
					{/each}
					{#each attention as item (item)}
						<Alert.Root class={attentionClass}>
							<AlertTriangle />
							<Alert.Description class="text-foreground"
								>{item}</Alert.Description
							>
						</Alert.Root>
					{/each}
				</section>
			{/if}

			{#if scheduled}
				<section
					class="flex flex-col gap-3 rounded-2xl border bg-card p-5"
					aria-labelledby="bw-next-batch"
				>
					<div class="flex flex-wrap items-start justify-between gap-3">
						<div class="flex flex-col gap-1">
							<h2
								id="bw-next-batch"
								class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
							>
								Next offer round
							</h2>
							<p class="font-semibold" data-testid="next-batch-headline">
								{nextBatchHeadline(next)}
							</p>
							{#if next.status !== "closed"}
								<p
									class="text-sm text-muted-foreground"
									data-testid="next-batch-size"
								>
									{nextBatchSize(next)}
								</p>
							{/if}
							{#if view.pause.paused && view.pause.pausedAt}
								<p class="text-xs text-muted-foreground">
									Paused {formatDublinInstant(view.pause.pausedAt)}{view.pause
										.pausedBy
										? ` by ${view.pause.pausedBy}`
										: ""}
								</p>
							{/if}
						</div>
						<div class="flex flex-wrap gap-2">
							<Button
								type="button"
								variant="outline"
								disabled={!view.fastTrackOpen && !view.fastTrackHoldersOnly}
								onclick={() => {
									fastTrackMounted = true;
									fastTrackDialogOpen = true;
								}}
							>
								<UserPlus /> Add a person
							</Button>
							<form
								{...command.enhance(async (instance) => {
									if (!(await instance.submit())) return;
									const result = instance.result;
									if (result?.ok)
										toast.success(
											view.pause.paused
												? "Automatic offers resumed"
												: "Automatic offers paused",
										);
									else if (result) toast.error(result.error);
								})}
							>
								<input {...command.fields.id.as("hidden", workshop.id)} />
								<Button
									type="submit"
									variant="outline"
									disabled={!!command.pending}
								>
									{#if view.pause.paused}<Play /> Resume offers{:else}<Pause /> Pause
										offers{/if}
								</Button>
							</form>
						</div>
					</div>

					{#if next.people.length}
						<ol
							class="flex flex-col gap-1.5"
							aria-label="People to offer a place"
						>
							{#each next.people as person, index (index)}
								<li
									class="flex flex-wrap items-center gap-3 rounded-xl border border-border/70 bg-background/50 px-4 py-3 text-sm"
								>
									<span class="w-6 text-right text-xs text-muted-foreground"
										>{index + 1}</span
									>
									<span class="min-w-24 flex-1 font-medium"
										>{personName(person)}</span
									>
									{#if person.minor}<Badge variant="outline">Minor</Badge>{/if}
									{#if person.confirms}<Badge
											variant="outline"
											class="border-emerald-700 text-emerald-900"
											data-testid="confirms"
											>Has credit · confirmation needed</Badge
										>{/if}
								</li>
							{/each}
						</ol>
					{:else if next.status !== "closed" && next.status !== "full"}
						<p class="text-sm text-muted-foreground">
							Nobody is waiting on the Waitlist right now.
						</p>
					{/if}
				</section>
			{/if}

			{#each groups as group (group.key)}
				{#if group.intakes.length}
					<section
						class="flex flex-col gap-3 rounded-2xl border bg-card p-5"
						aria-label={group.title}
					>
						<h2
							class="flex items-center gap-2 text-xs font-bold tracking-wider text-muted-foreground uppercase"
						>
							{group.title}
							<Badge variant="outline">{group.intakes.length}</Badge>
						</h2>
						<ul class="flex flex-col gap-1.5">
							{#each group.intakes as intake (intake.id)}
								{@const refund = refundLabel(intake)}
								<li class="flex items-center gap-2">
									<Button
										variant="outline"
										class="h-auto min-h-11 min-w-0 flex-1 flex-wrap justify-start gap-3 rounded-xl bg-background/50 px-4 py-3 text-left font-normal whitespace-normal shadow-none focus-visible:border-primary"
										aria-label={`${personName(intake)} — ${intakeStateLabel(intake.state)}`}
										onclick={() => (selectedIntakeId = intake.id)}
									>
										<span class="flex-1 font-medium">{personName(intake)}</span>
										{#if intake.minor}<Badge variant="outline">Minor</Badge
											>{/if}
										<span class="text-xs text-muted-foreground"
											>{intakeOrigin(intake)}</span
										>
										{#if refund}<Badge
												variant="outline"
												class={cn(
													refund.tone === "failed" &&
														"border-destructive bg-destructive text-white",
													refund.tone === "progress" &&
														"border-amber-500 text-amber-900",
													refund.tone === "done" &&
														"border-emerald-700 text-emerald-900",
												)}
												data-testid="refund-status">{refund.text}</Badge
											>{/if}
										{#if carriedFeeLabel(intake.carriedFee)}<Badge
												variant="outline"
												data-testid="carried-fee"
												class="capitalize"
												>{carriedFeeLabel(intake.carriedFee)}</Badge
											>{/if}
										{#if holdLabel(intake)}<Badge
												variant="outline"
												class="border-sky-600 text-sky-800"
												data-testid="hold-expiry">{holdLabel(intake)}</Badge
											>{/if}
										{#if intake.checkedInAt}<Badge
												variant="outline"
												class="border-emerald-600 text-emerald-800"
												data-testid="checked-in"
												>In {formatDublinTime(intake.checkedInAt)}</Badge
											>{/if}
										<Badge variant="secondary"
											>{intakeStateLabel(intake.state)}</Badge
										>
									</Button>
									{#if group.key === "attended"}
										{#if intake.standing === "attended" && canInvite}
											<InviteButton
												workshopId={workshop.id}
												intakeId={intake.id}
												name={personName(intake)}
											/>
										{:else if standingLabel(intake.standing)}
											<Badge
												variant="outline"
												class="border-emerald-700 text-emerald-900"
												data-testid="invitation-standing"
												>{standingLabel(intake.standing)}</Badge
											>
										{/if}
									{/if}
								</li>
							{/each}
						</ul>
					</section>
				{/if}
			{/each}

			{#if groups.every((group) => !group.intakes.length)}
				<Empty.Root class="border">
					<Empty.Header>
						<Empty.Title>Nobody contacted yet</Empty.Title>
						<Empty.Description
							>People appear here after they receive a place offer,
							automatically or from staff.</Empty.Description
						>
					</Empty.Header>
				</Empty.Root>
			{/if}
		</div>
	</div>
</div>

<Sheet.Root
	open={Boolean(selectedIntake)}
	onOpenChange={(open) => {
		if (!open) selectedIntakeId = null;
	}}
>
	<Sheet.Content
		side="right"
		class="w-full gap-0 overflow-hidden bg-popover text-popover-foreground sm:max-w-xl [&_[data-slot=button]]:min-h-11 [&_textarea]:min-h-24"
	>
		<Sheet.Header class="border-b p-6 pr-16">
			<Sheet.Title>Workshop place</Sheet.Title>
			<Sheet.Description
				>This person's workshop place, emails, activity and available actions.</Sheet.Description
			>
		</Sheet.Header>
		<div class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-6">
			{#if selectedIntake}
				{#key selectedIntake.id}
					<IntakeDetail workshopId={workshop.id} intake={selectedIntake} />
				{/key}
			{/if}
		</div>
	</Sheet.Content>
</Sheet.Root>

{#if scheduled && fastTrackMounted}
	<FastTrackDialog
		{workshop}
		fastTrackOpen={view.fastTrackOpen}
		holdersOnly={view.fastTrackHoldersOnly}
		{genders}
		bind:open={fastTrackDialogOpen}
	/>
{/if}

{#if scheduled && view.cancelPreview}
	<CancelWorkshopDialog
		{workshop}
		preview={view.cancelPreview}
		bind:open={cancelOpen}
	/>
{/if}

{#if scheduled}
	{#if settingsOpen}
		<WorkshopSettingsDialog {workshop} bind:open={settingsOpen} />
	{/if}
	{#if staffOpen}
		<StaffDialog
			{workshop}
			candidates={staffCandidates}
			bind:open={staffOpen}
		/>
	{/if}
	<!-- A reschedule remounts it, so the new values are the ones that follow. -->
	{#key `${workshop.id}:${workshop.date}:${workshop.startTime}:${workshop.venue}`}
		<RescheduleDialog
			{workshop}
			recipients={rescheduleRecipients(view)}
			bind:open={rescheduleOpen}
		/>
	{/key}
{/if}

<style>
.lifecycle {
	display: flex;
	flex-direction: column;
	gap: 0.25rem;
	padding: 0;
	list-style: none;
}
.timeline-step {
	position: relative;
	display: grid;
	grid-template-columns: 1.75rem minmax(0, 1fr);
	column-gap: 0.75rem;
	padding: 0.75rem 0.5rem;
}
.timeline-step::after {
	content: "";
	position: absolute;
	left: 1.375rem;
	top: 1.625rem;
	bottom: -1.875rem;
	border-left: 2px solid var(--border);
}
.timeline-step:last-child::after {
	display: none;
}
.timeline-marker {
	position: relative;
	z-index: 1;
	display: flex;
	width: 1.75rem;
	height: 1.75rem;
	align-items: center;
	justify-content: center;
}
</style>
