<!--
	ALE-384: the Fast-track dialog. Searches waiting people and people removed
	within the 3-month retention window (Phoenix's
	`beginnersWorkshopFastTrack.candidates`, the people `fast_track` would
	place), and offers "Not on the Waitlist? Add them". Placing someone
	contacts them at once with the Contact email; they pay like everyone else.
	Phoenix decides again under the lock, so a refusal is shown as is.
	ALE-388: after the Payment Cutoff only Carried Fee holders can be placed
	(`holdersOnly`): Phoenix lists only them, and there is no "Add them".
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
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";

let {
	workshop,
	fastTrackOpen,
	holdersOnly = false,
	genders,
	open = $bindable(false),
	searchCandidates,
}: {
	workshop: BeginnersWorkshop;
	/** Phoenix's console `fastTrackOpen`: before the Payment Cutoff. */
	fastTrackOpen: boolean;
	/** Phoenix's console `fastTrackHoldersOnly`: after the cutoff, Carried Fee holders only. */
	holdersOnly?: boolean;
	genders: string[];
	open?: boolean;
	/** Test seam: replaces the generated query function when given. */
	searchCandidates?: (
		query: string,
	) => Promise<BeginnersWorkshopFastTrackCandidate[]>;
} = $props();

const searchable = $derived(fastTrackOpen || holdersOnly);
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
		enabled: open && searchable && !addingNew,
	};
});

function placed(firstName: string | null) {
	toast.success(
		`${firstName || "They"} will receive an email offering a workshop place`,
	);
	open = false;
	addingNew = false;
	draft = "";
}
</script>

<Dialog.Root bind:open>
	<WorkshopDialog>
		<Dialog.Header>
			<Dialog.Title
				>Add a person to {formatCivilDate(workshop.date)}</Dialog.Title
			>
			<Dialog.Description>
				{addingNew
					? "Register their details and email a place offer. They must pay or confirm before their place is secured."
					: fastTrackOpen
						? "Offer someone a place now, without waiting for the next automatic offer round. They receive an email to pay or use their workshop credit. Places go to whoever pays or confirms first."
						: holdersOnly
							? "The payment deadline has passed. You can only add someone with workshop credit. They receive an email to confirm their place without paying again."
							: "The payment deadline has passed, so nobody can be added."}
			</Dialog.Description>
		</Dialog.Header>

		<div class="workshop-dialog-body grid gap-5">
			{#if !searchable}
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
					<div
						class="sticky -top-6 z-10 -mx-1 -mt-6 grid gap-3 bg-background px-1 pt-6 pb-3"
					>
						<Label for="fast-track-search">Search the Waitlist</Label>
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
					</div>

					{#if candidates.isPending}
						<div class="grid gap-2" aria-busy="true">
							<p role="status" class="text-sm">Searching the waitlist…</p>
							<Skeleton class="h-12 w-full" />
							<Skeleton class="h-12 w-full" />
						</div>
					{:else if candidates.isError}
						<p class="text-sm text-destructive" role="alert">
							Could not search the Waitlist. Try again.
						</p>
						<Button
							type="button"
							variant="outline"
							class="justify-self-start"
							onclick={() => candidates.refetch()}>Try search again</Button
						>
					{:else if candidates.data?.length}
						<ul
							class="divide-y overflow-hidden rounded-lg border bg-field text-sm"
							aria-label="People available to add"
						>
							{#each candidates.data as person (person.waitlistId)}
								{@const command = fastTrackWaitlistPerson.for(
									person.waitlistId,
								)}
								<li
									class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-3 p-4"
								>
									<div class="min-w-0 space-y-2">
										<div>
											<span class="block break-words font-medium"
												>{personName(person)}</span
											>
											<span
												class="block break-all text-sm text-muted-foreground"
												>{person.email}</span
											>
										</div>
									</div>
									<form
										{...command.enhance(async (instance) => {
											formError = null;
											if (!(await instance.submit())) return;
											const result = instance.result;
											if (result?.ok) placed(person.firstName);
											else if (result) formError = result.error;
										})}
										aria-label={`Add ${personName(person)} to workshop`}
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
											variant="outline"
											disabled={!!command.pending}
											>{command.pending ? "Offering…" : "Offer place"}</Button
										>
									</form>
									{#if person.minor || person.carriedFee || person.status === "removed"}
										<div class="col-span-2 flex flex-wrap gap-2">
											{#if person.minor}<Badge variant="outline">Minor</Badge
												>{/if}
											{#if person.carriedFee}<Badge variant="outline"
													>Has credit · confirmation needed</Badge
												>{/if}
											{#if person.status === "removed"}<Badge variant="outline"
													>Will rejoin the waitlist</Badge
												>{/if}
										</div>
									{/if}
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
					<Button type="button" variant="outline" onclick={() => (open = false)}
						>Close</Button
					>
					{#if fastTrackOpen}
						<Button
							type="button"
							variant="default"
							onclick={() => {
								formError = null;
								addingNew = true;
							}}>Not on the Waitlist? Add them</Button
						>
					{/if}
				</Dialog.Footer>
			{/if}
		</div>
	</WorkshopDialog>
</Dialog.Root>
