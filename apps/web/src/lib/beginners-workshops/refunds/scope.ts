/**
 * ALE-421: the refund scope of a Beginners' Workshop money command, mirroring
 * Phoenix's (a workshop id, or `{:person, waitlist_id}`): the console acts in
 * a workshop, the Waitlist tab on a person. The refund module mounts in
 * both, and this is the one place that knows what each scope makes stale.
 *
 * The console refreshes through its remote forms (a successful submission
 * reloads the page's data), so it names nothing. The Waitlist tab reads
 * through TanStack Query, so a success there invalidates the Waitlist pages,
 * the people read (credit, offered commands, refund choice) and the
 * person's workshop credit. Generated keys are `[{ _id: "<operation id>", … }]`
 * and TanStack matches a partial key, so each family is its `_id`.
 */
import type { QueryClient, QueryKey } from "@tanstack/svelte-query";

export type RefundScope =
	| { kind: "workshop"; workshopId: string }
	| { kind: "person"; waitlistId: string };

export function workshopScope(workshopId: string): RefundScope {
	return { kind: "workshop", workshopId };
}

export function personScope(waitlistId: string): RefundScope {
	return { kind: "person", waitlistId };
}

const PERSON_QUERIES: readonly QueryKey[] = [
	[{ _id: "waitlistEntries" }],
	[{ _id: "beginnersWorkshopPeopleIndex" }],
	[{ _id: "beginnersWorkshopCarriedFeesShow" }],
];

/** The TanStack query families a success in `scope` makes stale. */
export function staleQueries(scope: RefundScope): readonly QueryKey[] {
	return scope.kind === "person" ? PERSON_QUERIES : [];
}

/** Invalidates what a success in `scope` made stale. */
export async function refreshStale(
	scope: RefundScope,
	queryClient: QueryClient | null,
): Promise<void> {
	if (!queryClient) return;
	await Promise.all(
		staleQueries(scope).map((queryKey) =>
			queryClient.invalidateQueries({ queryKey }),
		),
	);
}
