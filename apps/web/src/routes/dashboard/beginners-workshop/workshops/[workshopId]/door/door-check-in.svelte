<!--
	ALE-390: door check-in, phone first. The "N of M in" counter and
	progress bar, a name search, To arrive / In / All, a big Check-in button
	per paid person and an inline undo naming who checked them in and when.
	Tapping a name shows what the door needs to know: medical conditions and,
	for a minor, the Guardian's name with a tap-to-call phone. Before the
	window opens it says when it does. Everything shown is Phoenix's door
	read model; each command answers the refreshed view.
-->
<script lang="ts">
import type { BeginnersWorkshopDoor } from "@dhc/api-client";
import { Baby, HeartPulse, Phone, Search, Undo2 } from "@lucide/svelte";
import { toast } from "svelte-sonner";
import {
	checkedInLine,
	type DoorFilter,
	doorCount,
	doorName,
	telHref,
	visiblePeople,
	windowNotice,
} from "#lib/beginners-workshops/door.js";
import { intakeStateLabel } from "#lib/beginners-workshops/console.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Progress } from "#lib/components/ui/progress/index.js";
import {
	ToggleGroup,
	ToggleGroupItem,
} from "#lib/components/ui/toggle-group/index.js";
import { cn } from "#lib/utils.js";
import {
	checkIn as checkInCommand,
	undoCheckIn as undoCheckInCommand,
} from "./door.remote";

type DoorCommand = (input: {
	id: string;
	intakeId: string;
}) => Promise<
	{ ok: true; data: BeginnersWorkshopDoor } | { ok: false; error: string }
>;

let {
	door,
	checkIn = checkInCommand,
	undoCheckIn = undoCheckInCommand,
}: {
	door: BeginnersWorkshopDoor;
	checkIn?: DoorCommand;
	undoCheckIn?: DoorCommand;
} = $props();

// The latest view: the load's, until a command answers a fresher one.
let view = $derived(door);
let search = $state("");
let filter = $state<DoorFilter>("to_arrive");
let expanded = $state<string | null>(null);
let pending = $state<string | null>(null);

const count = $derived(doorCount(view));
const notice = $derived(windowNotice(view));
const open = $derived(view.checkIn.window === "open");
const shown = $derived(visiblePeople(view.people, filter, search));
const filters = $derived([
	{ value: "to_arrive", label: `To arrive ${count.total - count.checkedIn}` },
	{ value: "in", label: `In ${count.checkedIn}` },
	{ value: "all", label: "All" },
] as const);

async function run(command: DoorCommand, intakeId: string) {
	pending = intakeId;
	try {
		const result = await command({ id: view.id, intakeId });
		if (result.ok) view = result.data;
		else toast.error(result.error);
	} catch {
		toast.error("Could not reach the server. Try again.");
	} finally {
		pending = null;
	}
}
</script>

<section class="flex flex-col gap-3" aria-label="Check-in">
	<div
		class="sticky top-0 z-10 flex flex-col gap-3 border-b bg-background/95 pt-2 pb-3 backdrop-blur"
	>
		<div class="flex items-baseline justify-between gap-3">
			<h2 class="font-heading text-xl">Check-in</h2>
			<span class="text-2xl font-bold tabular-nums" data-testid="door-count"
				>{count.label}</span
			>
		</div>
		<Progress
			value={count.checkedIn}
			max={count.total || 1}
			aria-label={count.label}
		/>
		{#if notice}
			<p
				class="rounded-xl border-2 border-amber-500 bg-amber-50 p-3 text-sm font-medium"
				data-testid="door-window"
			>
				{notice}
			</p>
		{/if}
		<div class="relative">
			<Search
				class="pointer-events-none absolute top-3.5 left-3 size-5 text-muted-foreground"
			/>
			<Input
				bind:value={search}
				type="search"
				placeholder="Find a name"
				aria-label="Find a name"
				class="h-12 pl-10 text-base"
				autocomplete="off"
			/>
		</div>
		{#if !search.trim()}
			<!-- Clicking the active item would clear a single ToggleGroup, so an
			     empty value is ignored. -->
			<ToggleGroup
				type="single"
				variant="outline"
				value={filter}
				onValueChange={(next) => {
					if (next) filter = next as DoorFilter;
				}}
				aria-label="Show"
				class="grid w-full grid-cols-3"
			>
				{#each filters as item (item.value)}
					<ToggleGroupItem
						value={item.value}
						class="min-h-11 font-semibold data-[state=on]:bg-secondary data-[state=on]:text-secondary-foreground"
					>
						{item.label}
					</ToggleGroupItem>
				{/each}
			</ToggleGroup>
		{/if}
	</div>

	<ul class="flex flex-col gap-2">
		{#each shown as person (person.id)}
			{@const name = doorName(person)}
			<li
				class={cn(
					"rounded-2xl border bg-card",
					person.checkedIn && "border-emerald-600 bg-emerald-50",
				)}
				data-testid="door-person"
			>
				<div class="flex items-center gap-3 p-3">
					<Button
						variant="ghost"
						class="h-auto min-w-0 flex-1 flex-col items-start gap-1 px-1 py-1 text-left whitespace-normal"
						aria-expanded={expanded === person.id}
						onclick={() =>
							(expanded = expanded === person.id ? null : person.id)}
					>
						<span class="truncate text-lg font-semibold">{name}</span>
						<span
							class="flex flex-wrap items-center gap-1.5 text-sm font-normal text-muted-foreground"
						>
							{#if person.pronouns}{person.pronouns}{/if}
							{#if person.minor}<Badge
									variant="outline"
									class="border-violet-600 text-violet-800"
									><Baby /> Minor</Badge
								>{/if}
							{#if person.medicalConditions}<Badge
									variant="outline"
									class="border-destructive text-destructive"
									><HeartPulse /> Medical</Badge
								>{/if}
							{#if person.state !== "paid"}<Badge variant="secondary"
									>{intakeStateLabel(person.state)}</Badge
								>{/if}
						</span>
					</Button>
					{#if person.checkedIn}
						<div class="flex flex-col items-end gap-1">
							<span class="text-sm font-semibold text-emerald-800"
								>{checkedInLine(person.checkedIn)}</span
							>
							{#if open}
								<Button
									size="sm"
									variant="ghost"
									class="h-9"
									aria-label={`Undo check-in for ${name}`}
									disabled={pending === person.id}
									onclick={() => run(undoCheckIn, person.id)}
									><Undo2 /> Undo</Button
								>
							{/if}
						</div>
					{:else if open && person.state === "paid"}
						<Button
							class="h-14 min-w-28 text-base"
							aria-label={`Check in ${name}`}
							disabled={pending === person.id}
							onclick={() => run(checkIn, person.id)}>Check in</Button
						>
					{/if}
				</div>
				{#if expanded === person.id}
					<div
						class="flex flex-col gap-2 border-t px-3 py-3 text-sm"
						data-testid="door-person-details"
					>
						{#if person.medicalConditions}
							<p class="flex gap-2">
								<HeartPulse class="size-4 shrink-0 text-destructive" />
								{person.medicalConditions}
							</p>
						{/if}
						{#if person.minor && person.guardian}
							<p class="flex flex-wrap items-center gap-2">
								<Phone class="size-4 shrink-0" />
								Guardian {person.guardian.name} ·
								<a
									class="font-semibold underline"
									href={telHref(person.guardian.phoneNumber)}
									>{person.guardian.phoneNumber}</a
								>
							</p>
						{:else if person.minor}
							<p class="text-muted-foreground">No Guardian on record.</p>
						{/if}
						{#if !person.medicalConditions && !person.minor}
							<p class="text-muted-foreground">Nothing else to know.</p>
						{/if}
					</div>
				{/if}
			</li>
		{:else}
			<li
				class="rounded-2xl border border-dashed p-6 text-center text-muted-foreground"
			>
				{search.trim()
					? "No one by that name. No walk-ins."
					: count.total === 0
						? "Nobody has a seat yet."
						: filter === "to_arrive"
							? "Everyone's in."
							: "Nobody in yet."}
			</li>
		{/each}
	</ul>
</section>
