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
import type { BeginnersWorkshopConsole } from "@dhc/api-client";
import {
	AlertTriangle,
	ArrowLeft,
	Ban,
	CalendarClock,
	Check,
	Circle,
	CircleDot,
	DoorOpen,
	Pause,
	Play,
	UserPlus,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { resolve } from "$app/paths";
import {
	consoleTimeline,
	formatDublinInstant,
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
import { doorTime } from "#lib/beginners-workshops/door.js";
import {
	formatCivilDate,
	formatFee,
	staffSummary,
} from "#lib/beginners-workshops/presentation.js";
import { rescheduleRecipients } from "#lib/beginners-workshops/reschedule.js";
import WorkshopAlerts from "#lib/components/beginners-workshops/workshop-alerts.svelte";
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

let {
	view,
	genders = [],
	canInvite = false,
}: {
	view: BeginnersWorkshopConsole;
	genders?: string[];
	canInvite?: boolean;
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
			"Free seats, but nobody is left waiting on the Waitlist. No Batch can go out until someone joins.",
	),
);
</script>

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

<div class="grid gap-6 py-4 lg:grid-cols-[19rem_1fr]">
	<aside class="flex flex-col gap-4">
		<Button
			variant="ghost"
			class="w-fit"
			href="/dashboard/beginners-workshop?tab=workshops"
		>
			<ArrowLeft /> Beginners' Workshops
		</Button>
		<div>
			<h1 class="font-heading text-2xl leading-tight">
				{formatCivilDate(workshop.date)}
			</h1>
			<p class="text-sm text-muted-foreground">
				{workshop.startTime} · {workshop.venue} · {formatFee(workshop.feeCents)}
			</p>
			<p class="text-sm" data-testid="console-staff">
				{staffSummary(workshop.staff)}
			</p>
		</div>
		{#if scheduled}
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
		{#if view.cancellation?.reason}
			<p class="text-sm" data-testid="cancel-reason">
				<span class="font-semibold">Reason:</span>
				{view.cancellation.reason}
			</p>
		{/if}
		<ol
			class="relative flex flex-col gap-3 border-l-2 border-border pl-4"
			aria-label="Lifecycle"
		>
			{#each steps as step, index (index)}
				<li
					class={cn(
						"relative",
						step.state === "skipped" && "opacity-40 line-through",
					)}
					data-state={step.state}
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
				</li>
			{/each}
		</ol>
		{#if workshop.status !== "cancelled"}<SeatMeter
				seats={workshop.seats}
				finalised={workshop.status === "finalised"}
			/>{/if}
	</aside>

	<div class="flex flex-col gap-5">
		<section
			class="flex flex-col gap-2 rounded-2xl border-2 border-primary bg-card p-5 shadow-[4px_4px_0_var(--color-secondary,#E5B524)]"
			aria-label="Now"
		>
			<p
				class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Now
			</p>
			<h2 class="font-heading text-2xl leading-tight">{now.title}</h2>
			<p class="text-sm text-muted-foreground">{now.body}</p>
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
					<DoorOpen /> Open the door view
				</Button>
			{/if}
		</section>

		{#if attention.length || workshop.alerts.length || view.failedRefunds.length || view.unpaidAfterWindow.length || view.unconfirmedCarriedFees.length}
			<section class="flex flex-col gap-2" aria-labelledby="bw-attention">
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
					<button
						type="button"
						class="flex items-center gap-3 rounded-xl border-2 border-amber-500 bg-amber-50 p-3 text-left text-sm"
						data-testid="unpaid-after-window"
						onclick={() => (selectedIntakeId = person.id)}
					>
						<AlertTriangle class="size-4 shrink-0" /><span
							>{unpaidAfterWindowText(person)}</span
						>
					</button>
				{/each}
				{#each view.unconfirmedCarriedFees as person (person.id)}
					<button
						type="button"
						class="flex items-center gap-3 rounded-xl border-2 border-amber-500 bg-amber-50 p-3 text-left text-sm"
						data-testid="unconfirmed-carried-fee"
						onclick={() => (selectedIntakeId = person.id)}
					>
						<AlertTriangle class="size-4 shrink-0" /><span
							>{unconfirmedCarriedFeeText(person)}</span
						>
					</button>
				{/each}
				{#each attention as item (item)}
					<div
						class="flex items-center gap-3 rounded-xl border-2 border-amber-500 bg-amber-50 p-3 text-sm"
					>
						<AlertTriangle class="size-4 shrink-0" /><span>{item}</span>
					</div>
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
							Next Batch
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
							<UserPlus /> Fast-track
						</Button>
						<form
							{...command.enhance(async (instance) => {
								if (!(await instance.submit())) return;
								const result = instance.result;
								if (result?.ok)
									toast.success(
										view.pause.paused ? "Batches resumed" : "Batches paused",
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
								{#if view.pause.paused}<Play /> Resume Batches{:else}<Pause /> Pause
									Batches{/if}
							</Button>
						</form>
					</div>
				</div>

				{#if next.people.length}
					<ol class="flex flex-col gap-1.5" aria-label="Proposed people">
						{#each next.people as person, index (index)}
							<li
								class="flex items-center gap-3 rounded-xl border px-3 py-2 text-sm"
							>
								<span class="w-6 text-right text-xs text-muted-foreground"
									>{index + 1}</span
								>
								<span class="flex-1 font-medium">{personName(person)}</span>
								{#if person.minor}<Badge variant="outline">Minor</Badge>{/if}
								{#if person.confirms}<Badge
										variant="outline"
										class="border-emerald-700 text-emerald-900"
										data-testid="confirms">confirms</Badge
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
				<section class="flex flex-col gap-2" aria-label={group.title}>
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
								<button
									type="button"
									class="flex min-w-0 flex-1 flex-wrap items-center gap-3 rounded-xl border bg-card px-3 py-2 text-left text-sm hover:border-primary focus-visible:border-primary"
									aria-label={`${personName(intake)} — ${intakeStateLabel(intake.state)}`}
									onclick={() => (selectedIntakeId = intake.id)}
								>
									<span class="flex-1 font-medium">{personName(intake)}</span>
									{#if intake.minor}<Badge variant="outline">Minor</Badge>{/if}
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
											>In {doorTime(intake.checkedInAt)}</Badge
										>{/if}
									<Badge variant="secondary"
										>{intakeStateLabel(intake.state)}</Badge
									>
								</button>
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
						>People appear here once a Batch or a Fast-track contacts them.</Empty.Description
					>
				</Empty.Header>
			</Empty.Root>
		{/if}
	</div>
</div>

<Sheet.Root
	open={Boolean(selectedIntake)}
	onOpenChange={(open) => {
		if (!open) selectedIntakeId = null;
	}}
>
	<Sheet.Content side="right" class="w-full overflow-y-auto sm:max-w-md">
		<Sheet.Header class="sr-only">
			<Sheet.Title>Intake</Sheet.Title>
			<Sheet.Description
				>This person's place in the workshop, its emails, history and commands.</Sheet.Description
			>
		</Sheet.Header>
		<div class="p-5">
			{#if selectedIntake}
				{#key selectedIntake.id}
					<IntakeDetail
						workshopId={workshop.id}
						workshopDate={workshop.date}
						feeCents={workshop.feeCents}
						intake={selectedIntake}
					/>
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
	<!-- A reschedule remounts it, so the new values are the ones that follow. -->
	{#key `${workshop.id}:${workshop.date}:${workshop.startTime}:${workshop.venue}`}
		<RescheduleDialog
			{workshop}
			recipients={rescheduleRecipients(view)}
			bind:open={rescheduleOpen}
		/>
	{/key}
{/if}
