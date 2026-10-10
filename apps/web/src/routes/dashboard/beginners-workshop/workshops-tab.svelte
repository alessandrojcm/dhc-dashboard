<!--
	ALE-378: the Workshops tab — Phoenix's list read model, upcoming first,
	then past and cancelled. Stage, seats and alerts are Phoenix's; this
	component names and lays them out. ALE-379: each row names its Staff and
	opens the Staff dialog and the door view; ALE-380: and the workshop console.
-->
<script lang="ts">
import type {
	BeginnersWorkshop,
	BeginnersWorkshopListResponse,
	BeginnersWorkshopStaffCandidate,
} from "@dhc/api-client";
import {
	CalendarPlus,
	DoorOpen,
	PanelsTopLeft,
	Settings2,
	Users,
} from "@lucide/svelte";
import { resolve } from "$app/paths";
import {
	dateTile,
	formatFee,
	stageLabel,
	staffSummary,
	stageTone,
} from "#lib/beginners-workshops/presentation.js";
import WorkshopAlerts from "#lib/components/beginners-workshops/workshop-alerts.svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import ScheduleWorkshopsDialog from "./schedule-workshops-dialog.svelte";
import SeatMeter from "./seat-meter.svelte";
import StaffDialog from "./staff-dialog.svelte";
import WorkshopSettingsDialog from "./workshop-settings-dialog.svelte";

let {
	workshops,
	candidates,
}: {
	workshops: BeginnersWorkshopListResponse["data"];
	candidates: BeginnersWorkshopStaffCandidate[];
} = $props();

let scheduleOpen = $state(false);
let settingsOpen = $state(false);
let editing = $state<BeginnersWorkshop | null>(null);
let staffOpen = $state(false);
let staffing = $state<BeginnersWorkshop | null>(null);

const toneClass = {
	neutral: "",
	attention: "border-secondary bg-secondary/25",
	warning: "border-amber-500 bg-amber-50 text-amber-900",
	live: "border-emerald-700 bg-emerald-600 text-white",
	ended: "border-destructive/50 text-destructive",
};

function editSettings(workshop: BeginnersWorkshop) {
	editing = workshop;
	settingsOpen = true;
}

function editStaff(workshop: BeginnersWorkshop) {
	staffing = workshop;
	staffOpen = true;
}
</script>

{#snippet row(workshop: BeginnersWorkshop)}
	{@const tile = dateTile(workshop.date)}
	<li
		class="grid grid-cols-[4.5rem_1fr] items-center gap-4 rounded-2xl border border-border bg-card p-4 shadow-[4px_4px_0_rgb(18_24_39/12%)] sm:grid-cols-[4.5rem_1fr_14rem_auto]"
		data-testid="beginners-workshop-row"
	>
		<div
			class="flex flex-col items-center rounded-xl border-2 border-primary/30 py-2"
		>
			<span
				class="text-xs font-bold tracking-widest text-muted-foreground uppercase"
				>{tile.weekday}</span
			>
			<span class="font-heading text-2xl leading-none">{tile.day}</span>
			<span class="text-xs font-semibold uppercase">{tile.month}</span>
		</div>
		<div class="flex min-w-0 flex-col gap-1.5">
			<div class="flex flex-wrap items-center gap-2">
				<span class="font-semibold">{workshop.startTime}</span>
				<Badge variant="outline" class={toneClass[stageTone(workshop.stage)]}
					>{stageLabel(workshop.stage)}</Badge
				>
				<WorkshopAlerts alerts={workshop.alerts} />
			</div>
			<p class="truncate text-sm text-muted-foreground">
				{workshop.venue} · {formatFee(workshop.feeCents)}
			</p>
			<p class="flex items-center gap-1.5 truncate text-sm">
				<Users class="size-4 shrink-0 text-muted-foreground" />
				<span class="truncate">{staffSummary(workshop.staff)}</span>
			</p>
		</div>
		<div class="col-span-2 sm:col-span-1">
			{#if workshop.status !== "cancelled"}<SeatMeter
					seats={workshop.seats}
					finalised={workshop.status === "finalised"}
				/>{/if}
		</div>
		<div class="flex items-center gap-1">
			<Button
				variant="outline"
				size="sm"
				href={resolve("/dashboard/beginners-workshop/workshops/[workshopId]", {
					workshopId: workshop.id,
				})}
				aria-label={`Open the console for ${workshop.date}`}
			>
				<PanelsTopLeft /> Console
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label={`Door view for ${workshop.date}`}
				href={resolve(
					"/dashboard/beginners-workshop/workshops/[workshopId]/door",
					{ workshopId: workshop.id },
				)}
			>
				<DoorOpen />
			</Button>
			{#if workshop.status === "scheduled"}
				<Button
					variant="ghost"
					size="icon"
					aria-label={`Staff for ${workshop.date}`}
					onclick={() => editStaff(workshop)}
				>
					<Users />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label={`Capacity, fee and cutoff for ${workshop.date}`}
					onclick={() => editSettings(workshop)}
				>
					<Settings2 />
				</Button>
			{/if}
		</div>
	</li>
{/snippet}

<div class="flex flex-col gap-6 py-4">
	<header class="flex flex-wrap items-end justify-between gap-4">
		<div>
			<h2 class="font-heading text-3xl">Beginners' Workshops</h2>
			<p class="text-sm text-muted-foreground">
				Never listed publicly. Seats come from the Waitlist through Batches.
			</p>
		</div>
		<Button onclick={() => (scheduleOpen = true)}
			><CalendarPlus /> Schedule workshops</Button
		>
	</header>

	<section class="flex flex-col gap-3" aria-labelledby="bw-upcoming">
		<h3
			id="bw-upcoming"
			class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
		>
			Upcoming
		</h3>
		{#if workshops.upcoming.length}
			<ul class="flex flex-col gap-3">
				{#each workshops.upcoming as workshop (workshop.id)}{@render row(
						workshop,
					)}{/each}
			</ul>
		{:else}
			<Empty.Root class="border">
				<Empty.Header>
					<Empty.Title>No upcoming workshops</Empty.Title>
					<Empty.Description
						>Schedule one or several to start filling them from the Waitlist.</Empty.Description
					>
				</Empty.Header>
			</Empty.Root>
		{/if}
	</section>

	{#if workshops.past.length}
		<section class="flex flex-col gap-3" aria-labelledby="bw-past">
			<h3
				id="bw-past"
				class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Past and cancelled
			</h3>
			<ul class="flex flex-col gap-3 opacity-90">
				{#each workshops.past as workshop (workshop.id)}{@render row(
						workshop,
					)}{/each}
			</ul>
		</section>
	{/if}
</div>

<ScheduleWorkshopsDialog bind:open={scheduleOpen} {candidates} />
{#if editing}
	{#key editing.id}
		<WorkshopSettingsDialog workshop={editing} bind:open={settingsOpen} />
	{/key}
{/if}
{#if staffing}
	{#key staffing.id}
		<StaffDialog workshop={staffing} {candidates} bind:open={staffOpen} />
	{/key}
{/if}
