<!-- PROTOTYPE — throwaway (ALE-372).
     Door B — Tile grid. One big tile per paid person, alphabetical and never reordered
     (moving tiles at the door causes mis-taps). Tap to check in; a checked tile offers Undo.
     ⓘ opens the run-boundary details (medical, guardian) in a bottom Sheet. -->
<script lang="ts">
import { Baby, Check, HeartPulse, Info, Phone } from "@lucide/svelte";
import { Button } from "#lib/components/ui/button/index.js";
import * as Sheet from "#lib/components/ui/sheet/index.js";
import { cn } from "#lib/utils.js";
import { fmtTime, proto } from "./bw-prototype-store.svelte";

let { workshopId }: { workshopId: string } = $props();
const w = $derived(proto.workshop(workshopId));
const roster = $derived(
	proto
		.intakesOf(w.id)
		.filter((intake) => intake.state === "paid")
		.sort((a, b) =>
			proto
				.person(a.personId)
				.firstName.localeCompare(proto.person(b.personId).firstName),
		),
);
const inCount = $derived(roster.filter((intake) => intake.checkedIn).length);
let details = $state<string | null>(null);
let armedUndo = $state<string | null>(null);
const detailIntake = $derived(details ? proto.intake(details) : undefined);
const detailPerson = $derived(
	detailIntake ? proto.person(detailIntake.personId) : undefined,
);

function tap(intakeId: string) {
	const intake = proto.intake(intakeId);
	if (!intake.checkedIn) {
		proto.checkIn(intakeId);
		armedUndo = null;
	} else armedUndo = armedUndo === intakeId ? null : intakeId;
}
const ring = $derived(2 * Math.PI * 34);
</script>

<div class="mx-auto flex max-w-md flex-col gap-4 pb-28">
	<header class="flex items-center gap-4 pt-2">
		<svg viewBox="0 0 80 80" class="size-20 -rotate-90" aria-hidden="true">
			<circle
				cx="40"
				cy="40"
				r="34"
				fill="none"
				stroke="currentColor"
				stroke-width="8"
				class="text-muted"
			/>
			<circle
				cx="40"
				cy="40"
				r="34"
				fill="none"
				stroke="currentColor"
				stroke-width="8"
				class="text-emerald-600 transition-all"
				stroke-dasharray={ring}
				stroke-dashoffset={ring * (1 - inCount / (roster.length || 1))}
				stroke-linecap="round"
			/>
		</svg>
		<div>
			<p class="text-3xl font-bold tabular-nums">
				{inCount}
				<span class="text-lg font-normal text-muted-foreground"
					>of {roster.length} in</span
				>
			</p>
			<p class="text-sm text-muted-foreground">
				{w.startTime} · {w.venue.split(",")[0]}
			</p>
		</div>
	</header>

	<ul class="grid grid-cols-2 gap-2.5">
		{#each roster as intake (intake.id)}
			{@const person = proto.person(intake.personId)}
			{@const minor = proto.isMinorAt(person, w)}
			<li class="relative">
				<button
					type="button"
					class={cn(
						"flex min-h-28 w-full cursor-pointer flex-col justify-between rounded-2xl border-2 p-3 pr-9 text-left transition active:scale-[0.98]",
						intake.checkedIn
							? "border-emerald-700 bg-emerald-600 text-white"
							: "border-border bg-card hover:border-primary",
					)}
					onclick={() => tap(intake.id)}
					aria-pressed={Boolean(intake.checkedIn)}
				>
					<span>
						<span class="block text-xl leading-tight font-bold"
							>{person.firstName}</span
						>
						<span
							class={cn(
								"block text-sm",
								intake.checkedIn ? "text-white/80" : "text-muted-foreground",
							)}>{person.lastName} · {person.pronouns}</span
						>
					</span>
					<span class="flex items-center gap-1.5 text-sm">
						{#if intake.checkedIn}<Check class="size-4" />
							{fmtTime(intake.checkedIn.at)}{:else}<span
								class="text-muted-foreground">Tap to check in</span
							>{/if}
						{#if minor}<Baby class="size-4" aria-label="Minor" />{/if}
						{#if person.medical}<HeartPulse
								class={cn("size-4", !intake.checkedIn && "text-destructive")}
								aria-label="Medical"
							/>{/if}
					</span>
				</button>
				<button
					type="button"
					class={cn(
						"absolute top-2 right-2 grid size-8 cursor-pointer place-items-center rounded-full",
						intake.checkedIn
							? "text-white hover:bg-white/20"
							: "text-muted-foreground hover:bg-muted",
					)}
					aria-label="Details for {person.firstName}"
					onclick={() => (details = intake.id)}
				>
					<Info class="size-4" />
				</button>
				{#if armedUndo === intake.id}
					<Button
						size="sm"
						variant="outline"
						class="absolute right-2 bottom-2 h-8 bg-background text-foreground"
						onclick={() => {
							proto.undoCheckIn(intake.id);
							armedUndo = null;
						}}>Undo</Button
					>
				{/if}
			</li>
		{/each}
	</ul>

	<div class="fixed inset-x-0 bottom-20 z-20 mx-auto w-full max-w-md px-3">
		<Button
			class="h-12 w-full text-base shadow-lg"
			variant={inCount === roster.length ? "default" : "outline"}
			onclick={() => {
				proto.dialog = { kind: "finish", workshopId: w.id };
			}}
		>
			Finish workshop
		</Button>
	</div>
</div>

<Sheet.Root
	open={details !== null}
	onOpenChange={(next) => !next && (details = null)}
>
	<Sheet.Content side="bottom" class="rounded-t-2xl p-5">
		{#if detailIntake && detailPerson}
			<Sheet.Header class="p-0">
				<Sheet.Title class="font-heading text-xl"
					>{detailPerson.firstName}
					{detailPerson.lastName}
					<span class="text-sm font-normal text-muted-foreground"
						>({detailPerson.pronouns})</span
					></Sheet.Title
				>
			</Sheet.Header>
			<div class="flex flex-col gap-3 py-3 text-sm">
				{#if detailPerson.medical}<p
						class="flex gap-2 rounded-lg border border-destructive/40 bg-destructive/5 p-2.5"
					>
						<HeartPulse class="size-4 shrink-0 text-destructive" />
						{detailPerson.medical}
					</p>{/if}
				{#if proto.isMinorAt(detailPerson, w) && detailPerson.guardian}
					<p class="flex items-center gap-2">
						<Phone class="size-4" /> Guardian {detailPerson.guardian.name} ·
						<a
							class="underline"
							href="tel:{detailPerson.guardian.phone.replaceAll(' ', '')}"
							>{detailPerson.guardian.phone}</a
						>
					</p>
				{/if}
				<p class="text-muted-foreground">
					{detailIntake.checkedIn
						? `Checked in ${fmtTime(detailIntake.checkedIn.at)} by ${detailIntake.checkedIn.by}`
						: "Not checked in yet"}
				</p>
			</div>
		{/if}
	</Sheet.Content>
</Sheet.Root>
