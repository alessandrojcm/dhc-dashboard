<!--
	ALE-380: the coordinator console of one Beginners' Workshop — the
	lifecycle timeline, the "Now" card, Needs attention, the Next Batch
	preview with Pause/Resume beside it, and the roster grouped by meaning.
	Everything shown is Phoenix's console read model. Pause/Resume and
	(ALE-384) Fast-track are its commands; Batches themselves come only from
	the system sweep.
-->
<script lang="ts">
import type { BeginnersWorkshopConsole } from "@dhc/api-client";
import {
	AlertTriangle,
	ArrowLeft,
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
	nextBatchHeadline,
	nextBatchSize,
	nowCard,
	personName,
	rosterGroups,
	type TimelineStep,
} from "#lib/beginners-workshops/console.js";
import { doorTime } from "#lib/beginners-workshops/door.js";
import {
	formatCivilDate,
	formatFee,
	staffSummary,
} from "#lib/beginners-workshops/presentation.js";
import WorkshopAlerts from "#lib/components/beginners-workshops/workshop-alerts.svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import { cn } from "#lib/utils.js";
import SeatMeter from "../../seat-meter.svelte";
import { pauseBatches, resumeBatches } from "./console.remote";
import FastTrackDialog from "./fast-track-dialog.svelte";

let {
	view,
	genders = [],
}: { view: BeginnersWorkshopConsole; genders?: string[] } = $props();

let fastTrackDialogOpen = $state(false);
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
			{#if workshop.stage === "today_before_check_in" || workshop.stage === "check_in_open"}
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

		{#if attention.length || workshop.alerts.length}
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
							disabled={!view.fastTrackOpen}
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
							<li
								class="flex flex-wrap items-center gap-3 rounded-xl border bg-card px-3 py-2 text-sm"
							>
								<span class="flex-1 font-medium">{personName(intake)}</span>
								{#if intake.minor}<Badge variant="outline">Minor</Badge>{/if}
								<span class="text-xs text-muted-foreground"
									>{intakeOrigin(intake)}</span
								>
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
							</li>
						{/each}
					</ul>
				</section>
			{/if}
		{/each}

		{#if !view.roster.seated.length && !view.roster.asked.length && !view.roster.out.length}
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

{#if scheduled && fastTrackMounted}
	<FastTrackDialog
		{workshop}
		fastTrackOpen={view.fastTrackOpen}
		{genders}
		bind:open={fastTrackDialogOpen}
	/>
{/if}
