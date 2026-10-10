<!--
	PROTOTYPE — throwaway (ALE-372)
	Beginners' Workshop coordinator console and door check-in, on the throwaway
	`/dashboard/prototype/beginners-workshop` route. `?screen=` picks the surface,
	`?w=` the workshop, `?variant=` the layout (console A/B/C, door A/B).
	Everything is in memory (bw-prototype-store.svelte.ts); nothing talks to Phoenix.
-->
<script lang="ts">
import { RotateCcw } from "@lucide/svelte";
import { page } from "$app/state";
import { Button } from "#lib/components/ui/button/index.js";
import PrototypeSwitcher from "#lib/components/ui/prototype-switcher.svelte";
import { cn } from "#lib/utils.js";
import { go, type Screen } from "./bw-nav";
import {
	ASSISTANT_ID,
	fmtDayLong,
	fmtDayTime,
	NOW,
	proto,
} from "./bw-prototype-store.svelte";
import CommandDialogs from "./command-dialogs.svelte";
import ConsoleA from "./console-variant-a-tabs.svelte";
import ConsoleB from "./console-variant-b-board.svelte";
import ConsoleC from "./console-variant-c-cockpit.svelte";
import DoorA from "./door-variant-a-list.svelte";
import DoorB from "./door-variant-b-tiles.svelte";
import EmailTemplates from "./email-templates.svelte";
import InvitableView from "./invitable-view.svelte";
import WorkshopsList from "./workshops-list.svelte";

const SCREENS: { id: Screen; label: string }[] = [
	{ id: "workshops", label: "Workshops" },
	{ id: "console", label: "Console" },
	{ id: "door", label: "Door check-in" },
	{ id: "invitable", label: "Invitable" },
	{ id: "templates", label: "Email templates" },
];
const VARIANTS = {
	console: [
		{ id: "A", label: "A — Tabbed console" },
		{ id: "B", label: "B — Pipeline board" },
		{ id: "C", label: "C — Next-action cockpit" },
	],
	door: [
		{ id: "A", label: "A — Search list" },
		{ id: "B", label: "B — Name tiles" },
	],
} satisfies Partial<Record<Screen, { id: string; label: string }[]>>;

const screen = $derived<Screen>(
	SCREENS.find((item) => item.id === page.url.searchParams.get("screen"))?.id ??
		"workshops",
);
const variants = $derived(
	screen === "console" || screen === "door" ? VARIANTS[screen] : [],
);
const rawVariant = $derived(page.url.searchParams.get("variant") ?? "A");
const variant = $derived(
	variants.some((candidate) => candidate.id === rawVariant) ? rawVariant : "A",
);
const workshopId = $derived(
	page.url.searchParams.get("w") ?? (screen === "door" ? "w-oct09" : "w-oct24"),
);
const w = $derived(
	proto.workshops.find((candidate) => candidate.id === workshopId),
);
const assistant = $derived(proto.viewer === "assistant");
const assigned = $derived(
	w
		? w.coachId === ASSISTANT_ID || w.assistantIds.includes(ASSISTANT_ID)
		: false,
);
let showTry = $state(false);
</script>

<svelte:head>
	<title>Beginners' Workshop console prototype | Dublin HEMA Club</title>
</svelte:head>

{#snippet notFound()}
	<div
		class="mx-auto max-w-md rounded-2xl border border-dashed p-8 text-center"
	>
		<p class="font-heading text-2xl">404</p>
		<p class="text-sm text-muted-foreground">
			Concealed: Seán isn't assigned here, and has no <code
				>beginners.workshops.manage</code
			>.
		</p>
	</div>
{/snippet}

<div
	class="mx-auto flex max-w-7xl flex-col gap-6 px-3 py-4 pb-36 sm:px-6 lg:px-8"
>
	<section
		class="flex flex-col gap-3 rounded-2xl border-2 border-dashed border-[#ccff00] bg-zinc-950 px-4 py-3 text-[#ccff00]"
	>
		<div class="flex flex-wrap items-center gap-x-4 gap-y-2">
			<p class="text-xs font-bold tracking-[0.16em] uppercase">
				PROTOTYPE — throwaway · ALE-372
			</p>
			<p class="text-xs text-[#ccff00]/70">
				Fixture clock: {fmtDayTime(NOW)} · one workshop per lifecycle moment
			</p>
			<div
				class="ml-auto flex items-center gap-1 rounded-full border border-[#ccff00]/40 p-0.5 text-xs"
			>
				{#each [["coordinator", "Coordinator"], ["assistant", "Assistant (Seán)"]] as const as [id, label] (id)}
					<button
						type="button"
						class={cn(
							"cursor-pointer rounded-full px-3 py-1",
							proto.viewer === id && "bg-[#ccff00] font-bold text-zinc-950",
						)}
						onclick={() => {
							proto.viewer = id;
						}}>{label}</button
					>
				{/each}
			</div>
			<Button
				size="sm"
				variant="ghost"
				class="h-7 text-[#ccff00] hover:bg-[#ccff00]/15 hover:text-[#ccff00]"
				onclick={() => proto.reset()}><RotateCcw /> Reset</Button
			>
		</div>
		<nav class="flex flex-wrap gap-1 text-sm" aria-label="Prototype screens">
			{#each SCREENS as item (item.id)}
				<button
					type="button"
					class={cn(
						"cursor-pointer rounded-lg px-3 py-1",
						screen === item.id
							? "bg-[#ccff00] font-bold text-zinc-950"
							: "hover:bg-[#ccff00]/15",
					)}
					onclick={() =>
						go(
							item.id,
							item.id === "door"
								? "w-oct09"
								: item.id === "console"
									? workshopId
									: undefined,
						)}>{item.label}</button
				>
			{/each}
			<button
				type="button"
				class="ml-auto cursor-pointer text-xs underline underline-offset-2"
				onclick={() => (showTry = !showTry)}
				>{showTry ? "Hide" : "What to try"}</button
			>
		</nav>
		{#if showTry}
			<ol
				class="grid list-decimal gap-1 pl-5 text-sm text-[#ccff00]/85 md:grid-cols-2"
			>
				<li>
					<strong>24 Oct</strong>: Batch 1 window ended → send Batch 2 (window
					field; Carried Fee holders “confirm”).
				</li>
				<li>
					<strong>7 Nov</strong>: a live Seat Hold, Carried Fee confirms, a late
					payment refunded automatically (Closed).
				</li>
				<li>
					<strong>11 Oct</strong>: payment closed; a failed refund to retry or
					record as manual.
				</li>
				<li>
					<strong>Today 9 Oct 19:00</strong>: door view (check in, undo, Finish)
					→ the console turns finalised → Invite.
				</li>
				<li>
					<strong>26 Sep</strong>: Invite per person (one click comes back
					refused: someone else got there first), correct attendance; invited
					people lock.
				</li>
				<li>
					<strong>17 Oct</strong>: cancelled, read-only; refund someone's
					Carried Fee from their Intake.
				</li>
				<li>
					<strong>28 Nov</strong>: unstaffed, no Batch: assign staff, send Batch
					1; reschedule or cancel any upcoming one.
				</li>
				<li>
					Fast-track a new person (try ciaran.walsh@example.ie); switch to <strong
						>Assistant</strong
					> for My Beginners' Workshops.
				</li>
			</ol>
		{/if}
	</section>

	{#key `${screen}-${variant}-${workshopId}`}
		{#if screen === "workshops"}
			<WorkshopsList />
		{:else if screen === "templates"}
			{#if assistant}{@render notFound()}{:else}<EmailTemplates />{/if}
		{:else if screen === "invitable"}
			{#if assistant}{@render notFound()}{:else}<InvitableView />{/if}
		{:else if !w}
			<p>Unknown workshop.</p>
		{:else if screen === "console"}
			{#if assistant}
				{#if assigned}
					<div
						class="mx-auto flex max-w-md flex-col items-center gap-3 rounded-2xl border border-dashed p-8 text-center"
					>
						<p class="text-sm text-muted-foreground">
							Assumption to react to: assigned staff have no console. Their
							whole view of {fmtDayLong(w.date)} is the door view (roster + check-in).
						</p>
						<Button onclick={() => go("door", w.id)}>Open door view</Button>
					</div>
				{:else}{@render notFound()}{/if}
			{:else if variant === "B"}
				<ConsoleB workshopId={w.id} />
			{:else if variant === "C"}
				<ConsoleC workshopId={w.id} />
			{:else}
				<ConsoleA workshopId={w.id} />
			{/if}
		{:else if screen === "door"}
			{#if assistant && !assigned}
				{@render notFound()}
			{:else if proto.checkInOpen(w)}
				{#if variant === "B"}<DoorB workshopId={w.id} />{:else}<DoorA
						workshopId={w.id}
					/>{/if}
			{:else}
				{@const seats = proto.seats(w)}
				<div
					class="mx-auto flex max-w-md flex-col gap-2 rounded-2xl border bg-card p-6 text-center"
				>
					<p class="font-heading text-2xl">
						{fmtDayLong(w.date)} · {w.startTime}
					</p>
					{#if w.status === "finalised"}
						<p class="text-sm">
							Finalised {fmtDayTime(w.finalisedAt as string)} by {w.finalisedBy}:
							{proto
								.intakesOf(w.id)
								.filter((intake) => intake.state === "attended").length} attended,
							{proto
								.intakesOf(w.id)
								.filter((intake) => intake.state === "no_show").length} no-show.
						</p>
						<p class="text-xs text-muted-foreground">
							Check-in is closed. Only a coordinator can correct attendance now.
						</p>
					{:else if w.status === "cancelled"}
						<p class="text-sm">Cancelled. Nothing to check in.</p>
					{:else}
						<p class="text-sm">
							Check-in opens {fmtDayTime(proto.checkInOpensAt(w))} (1 hour before
							the start). {seats.paid} paid so far.
						</p>
					{/if}
					{#if !assistant}<Button
							variant="outline"
							class="mx-auto mt-2"
							onclick={() => go("console", w.id)}>Back to the console</Button
						>{/if}
				</div>
			{/if}
		{/if}
	{/key}
</div>

<CommandDialogs />
{#if variants.length}<PrototypeSwitcher {variants} current={variant} />{/if}
