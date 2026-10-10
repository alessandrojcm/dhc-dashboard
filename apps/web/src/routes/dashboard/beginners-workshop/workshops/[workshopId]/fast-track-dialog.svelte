<!--
	ALE-384: the Fast-track dialog. Searches waiting people and people removed
	within the 3-month retention window (Phoenix's
	`beginnersWorkshopFastTrack.candidates`, the people `fast_track` would
	place), and offers "Not on the Waitlist? Add them". Placing someone
	contacts them at once with the Contact email; they pay like everyone else.
	Phoenix decides again under the lock, so a refusal is shown as is.
-->
<script lang="ts">
import {
	beginnersWorkshopFastTrackCandidatesOptions,
	type BeginnersWorkshop,
	type BeginnersWorkshopFastTrackCandidate,
} from "@dhc/api-client";
import { Search } from "@lucide/svelte";
import { createQuery } from "@tanstack/svelte-query";
import { toast } from "svelte-sonner";
import { personName } from "#lib/beginners-workshops/console.js";
import { formatCivilDate } from "#lib/beginners-workshops/presentation.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import { Skeleton } from "#lib/components/ui/skeleton/index.js";
import { fastTrackWaitlistPerson } from "./console.remote";
import FastTrackNewPerson from "./fast-track-new-person.svelte";

let {
	workshop,
	fastTrackOpen,
	genders,
	open = $bindable(false),
	searchCandidates,
}: {
	workshop: BeginnersWorkshop;
	/** Phoenix's console `fastTrackOpen`: before the Payment Cutoff. */
	fastTrackOpen: boolean;
	genders: string[];
	open?: boolean;
	/** Test seam: replaces the generated query function when given. */
	searchCandidates?: (
		query: string,
	) => Promise<BeginnersWorkshopFastTrackCandidate[]>;
} = $props();

let draft = $state("");
let search = $state("");
let addingNew = $state(false);
let formError = $state<string | null>(null);

// A short debounce so typing a name issues one search, not one per key.
$effect(() => {
	const next = draft.trim();
	const timer = setTimeout(() => (search = next), 250);
	return () => clearTimeout(timer);
});

const candidates = createQuery(() => {
	const options = beginnersWorkshopFastTrackCandidatesOptions({
		path: { id: workshop.id },
		query: search ? { q: search } : {},
	});
	const request = searchCandidates;
	return {
		...options,
		...(request && {
			queryFn: async () => ({ data: await request(search) }),
		}),
		select: (response: { data: BeginnersWorkshopFastTrackCandidate[] }) =>
			response.data,
		enabled: open && fastTrackOpen && !addingNew,
	};
});

function placed(firstName: string | null) {
	toast.success(
		`${firstName || "They"} ${firstName ? "is" : "are"} fast-tracked and will get the Contact email`,
	);
	open = false;
	addingNew = false;
	draft = "";
}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="max-h-[90svh] overflow-y-auto sm:max-w-xl">
		<Dialog.Header>
			<Dialog.Title
				>Fast-track into {formatCivilDate(workshop.date)}</Dialog.Title
			>
			<Dialog.Description>
				{fastTrackOpen
					? "Outside Batch order. They're contacted now and pay the fee like anyone else; seats go to whoever pays first."
					: "Payment is closed for this workshop, so nobody can be fast-tracked."}
			</Dialog.Description>
		</Dialog.Header>

		{#if !fastTrackOpen}
			<Dialog.Footer>
				<Button type="button" variant="outline" onclick={() => (open = false)}
					>Close</Button
				>
			</Dialog.Footer>
		{:else if addingNew}
			<FastTrackNewPerson
				workshopId={workshop.id}
				{genders}
				onBack={() => (addingNew = false)}
				onDone={placed}
			/>
		{:else}
			<div class="grid gap-3">
				<Label for="fast-track-search" class="sr-only"
					>Search the Waitlist</Label
				>
				<div class="relative">
					<Search
						class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground"
					/>
					<Input
						id="fast-track-search"
						type="search"
						bind:value={draft}
						placeholder="Search waiting, or removed in the last 3 months"
						class="pl-9"
					/>
				</div>

				{#if candidates.isPending}
					<div class="grid gap-2" aria-busy="true">
						<Skeleton class="h-12 w-full" />
						<Skeleton class="h-12 w-full" />
					</div>
				{:else if candidates.isError}
					<p class="text-sm text-destructive" role="alert">
						Could not search the Waitlist. Try again.
					</p>
				{:else if candidates.data?.length}
					<ul
						class="divide-y rounded-lg border text-sm"
						aria-label="Fast-track candidates"
					>
						{#each candidates.data as person (person.waitlistId)}
							{@const command = fastTrackWaitlistPerson.for(person.waitlistId)}
							<li class="flex flex-wrap items-center gap-2 px-3 py-2">
								<span class="min-w-0 flex-1">
									<span class="block font-medium">{personName(person)}</span>
									<span class="block truncate text-xs text-muted-foreground"
										>{person.email}</span
									>
								</span>
								{#if person.minor}<Badge variant="outline">Minor</Badge>{/if}
								{#if person.status === "removed"}<Badge variant="outline"
										>Removed · restores</Badge
									>{/if}
								<form
									{...command.enhance(async (instance) => {
										formError = null;
										if (!(await instance.submit())) return;
										const result = instance.result;
										if (result?.ok) placed(person.firstName);
										else if (result) formError = result.error;
									})}
									aria-label={`Fast-track ${personName(person)}`}
								>
									<input {...command.fields.id.as("hidden", workshop.id)} />
									<input
										{...command.fields.waitlistId.as(
											"hidden",
											person.waitlistId,
										)}
									/>
									<Button
										type="submit"
										size="sm"
										variant="outline"
										disabled={!!command.pending}>Fast-track</Button
									>
								</form>
							</li>
						{/each}
					</ul>
				{:else}
					<Empty.Root class="border py-6">
						<Empty.Header>
							<Empty.Title>No one matches</Empty.Title>
							<Empty.Description
								>Nobody waiting, or removed in the last 3 months, matches that
								search.</Empty.Description
							>
						</Empty.Header>
					</Empty.Root>
				{/if}

				{#if formError}
					<p class="text-sm text-destructive" role="alert">{formError}</p>
				{/if}
			</div>
			<Dialog.Footer>
				<Button
					type="button"
					variant="ghost"
					onclick={() => {
						formError = null;
						addingNew = true;
					}}>Not on the Waitlist? Add them</Button
				>
			</Dialog.Footer>
		{/if}
	</Dialog.Content>
</Dialog.Root>
