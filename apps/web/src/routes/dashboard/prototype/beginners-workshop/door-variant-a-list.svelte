<!-- PROTOTYPE — throwaway (ALE-372).
     Door A — Search-first list. Big check-in buttons, search at the top, Finish at the bottom.
     Shows only the `beginners.workshops.run` data boundary: name, pronouns, state,
     check-in, medical conditions, guardian name and phone for minors. -->
<script lang="ts">
import { Baby, HeartPulse, Phone, Search, Undo2 } from "@lucide/svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Progress } from "#lib/components/ui/progress/index.js";
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
let query = $state("");
let show = $state<"to_arrive" | "in" | "all">("to_arrive");
let open = $state<string | null>(null);

const visible = $derived(
	roster.filter((intake) => {
		const person = proto.person(intake.personId);
		if (query)
			return `${person.firstName} ${person.lastName}`
				.toLowerCase()
				.includes(query.toLowerCase());
		if (show === "to_arrive") return !intake.checkedIn;
		if (show === "in") return Boolean(intake.checkedIn);
		return true;
	}),
);
</script>

<div class="mx-auto flex max-w-md flex-col gap-3 pb-28">
	<header
		class="sticky top-0 z-10 flex flex-col gap-3 rounded-b-2xl border-b bg-background/95 pt-2 pb-3 backdrop-blur"
	>
		<div class="flex items-baseline justify-between">
			<h1 class="font-heading text-xl">Check-in · {w.startTime}</h1>
			<span class="text-2xl font-bold tabular-nums"
				>{inCount}<span class="text-base font-normal text-muted-foreground"
					>/{roster.length}</span
				></span
			>
		</div>
		<Progress value={inCount} max={roster.length || 1} />
		<div class="relative">
			<Search class="absolute top-3.5 left-3 size-5 text-muted-foreground" />
			<Input
				bind:value={query}
				placeholder="Find a name"
				class="h-12 pl-10 text-base"
				autocomplete="off"
			/>
		</div>
		{#if !query}
			<div class="grid grid-cols-3 gap-1 rounded-xl bg-muted p-1 text-sm">
				{#each [["to_arrive", `To arrive ${roster.length - inCount}`], ["in", `In ${inCount}`], ["all", "All"]] as const as [key, label] (key)}
					<button
						type="button"
						class={cn(
							"min-h-10 cursor-pointer rounded-lg",
							show === key && "bg-background font-semibold shadow-sm",
						)}
						onclick={() => (show = key)}>{label}</button
					>
				{/each}
			</div>
		{/if}
	</header>

	<ul class="flex flex-col gap-2">
		{#each visible as intake (intake.id)}
			{@const person = proto.person(intake.personId)}
			{@const minor = proto.isMinorAt(person, w)}
			<li
				class={cn(
					"rounded-2xl border bg-card",
					intake.checkedIn && "border-emerald-600 bg-emerald-50",
				)}
			>
				<div class="flex items-center gap-3 p-3">
					<button
						type="button"
						class="flex min-w-0 flex-1 cursor-pointer flex-col text-left"
						onclick={() => (open = open === intake.id ? null : intake.id)}
					>
						<span class="truncate text-lg font-semibold"
							>{person.firstName} {person.lastName}</span
						>
						<span
							class="flex flex-wrap items-center gap-1.5 text-sm text-muted-foreground"
						>
							{person.pronouns}
							{#if minor}<Badge
									variant="outline"
									class="border-violet-600 text-violet-800"
									><Baby /> Minor</Badge
								>{/if}
							{#if person.medical}<Badge
									variant="outline"
									class="border-destructive text-destructive"
									><HeartPulse /> Medical</Badge
								>{/if}
						</span>
					</button>
					{#if intake.checkedIn}
						<div class="flex flex-col items-end gap-1">
							<span class="text-sm font-semibold text-emerald-800"
								>In {fmtTime(intake.checkedIn.at)}</span
							>
							<Button
								size="sm"
								variant="ghost"
								class="h-8"
								onclick={() => proto.undoCheckIn(intake.id)}
								><Undo2 /> Undo</Button
							>
						</div>
					{:else}
						<Button
							class="h-14 min-w-28 text-base"
							onclick={() => proto.checkIn(intake.id)}>Check in</Button
						>
					{/if}
				</div>
				{#if open === intake.id}
					<div class="flex flex-col gap-2 border-t px-3 py-3 text-sm">
						{#if person.medical}<p class="flex gap-2">
								<HeartPulse class="size-4 shrink-0 text-destructive" />
								{person.medical}
							</p>{/if}
						{#if minor && person.guardian}
							<p class="flex items-center gap-2">
								<Phone class="size-4 shrink-0" /> Guardian {person.guardian
									.name} ·
								<a
									class="underline"
									href="tel:{person.guardian.phone.replaceAll(' ', '')}"
									>{person.guardian.phone}</a
								>
							</p>
						{/if}
						{#if intake.checkedIn}<p class="text-muted-foreground">
								Checked in by {intake.checkedIn.by}
							</p>{/if}
						{#if !person.medical && !minor}<p class="text-muted-foreground">
								Nothing else to know.
							</p>{/if}
					</div>
				{/if}
			</li>
		{:else}
			<li
				class="rounded-2xl border border-dashed p-6 text-center text-muted-foreground"
			>
				{query
					? "No one by that name. No walk-ins."
					: show === "to_arrive"
						? "Everyone's in."
						: "Nobody yet."}
			</li>
		{/each}
	</ul>

	<div class="fixed inset-x-0 bottom-20 z-20 mx-auto w-full max-w-md px-3">
		<Button
			variant="outline"
			class="h-12 w-full border-2 bg-background text-base shadow-lg"
			onclick={() => {
				proto.dialog = { kind: "finish", workshopId: w.id };
			}}
		>
			Finish workshop ({roster.length - inCount} will be no-show)
		</Button>
	</div>
</div>
