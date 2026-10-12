/**
 * The beginners' Waitlist table: one interface for reading a page of Waitlist
 * entries and for every action the desktop table and the mobile cards offer.
 *
 * The Waitlist view is the queue: it lists `waiting` people by default, with
 * `removed` people behind the standing filter (ALE-375). Waitlist Status is
 * not editable here — it changes only through named commands — so the
 * writes are the entry's admin notes and `restore` (ALE-376), which returns a
 * removed person to the queue with their original date. Withdraw (ALE-387)
 * and Delete (ALE-396) are the Beginners' Workshop boundary's commands, not
 * the Waitlist's — they may close the person's open Intake and settle their
 * Carried Fee — so the refund module runs them (ALE-421, person scope), and
 * invalidates this table's queries after a success.
 * Which of these a row offers is Phoenix's (ALE-417), never worked out
 * here: Restore from the entry's own `availableCommands` (the Waitlist's
 * retention rule), Withdraw and Delete — and each person's workshop credit
 * status and refund-or-forfeit choice — from Beginners' Workshops' person
 * read (`beginnersWorkshopPeople.index`), one extra query over the page's
 * ids, because the Waitlist API cannot know them. `offers` merges both
 * lists. The controller owns the URL-backed list request, cache
 * invalidation and the toasts; markup only renders and calls these actions.
 */
import {
	beginnersWorkshopPeopleIndexOptions,
	type BeginnersCarriedFeeStatus,
	type BeginnersWorkshopPeople,
	type BeginnersWorkshopRefundChoice,
	type BeginnersWorkshopPersonCommand,
	waitlistEntriesOptions,
	waitlistEntriesQueryKey,
	waitlistRestoreEntryMutation,
	waitlistUpdateEntryMutation,
	type Options,
	type WaitlistEntriesData,
	type WaitlistEntriesResponse2,
	type WaitlistEntry,
	type WaitlistEntryCommand,
	type WaitlistRestoreEntryData,
	type WaitlistRestoreEntryResponse,
	type WaitlistUpdateEntryData,
	type WaitlistUpdateEntryResponse,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	keepPreviousData,
	useQueryClient,
	type QueryClient,
} from "@tanstack/svelte-query";
import { toast } from "svelte-sonner";
import { apiProblem } from "#lib/api-error.js";
import type { CarriedFeePanelDeps } from "./carried-fee-panel.svelte.js";
import {
	createCursorTableUrl,
	type CursorTableNavigate,
} from "#lib/cursor-table-url.svelte.js";

export type WaitlistNotify = {
	success(message: string): void;
	error(message: string): void;
};

/** The standings the Waitlist view can list; `waiting` is the queue. */
export type WaitlistStanding = NonNullable<
	NonNullable<WaitlistEntriesData["query"]>["status"]
>;

export const WAITLIST_STANDINGS = [
	{ value: "waiting", label: "Waiting" },
	{ value: "removed", label: "Removed" },
] as const satisfies ReadonlyArray<{ value: WaitlistStanding; label: string }>;

const DEFAULT_STANDING: WaitlistStanding = "waiting";

function isStanding(value: string | null): value is WaitlistStanding {
	return WAITLIST_STANDINGS.some((standing) => standing.value === value);
}

export type WaitlistTableDeps = {
	/** Defaults to the query client from context. */
	queryClient?: QueryClient;
	/** Request functions; each defaults to the generated `@dhc/api-client` call. */
	listEntries?: (
		options: Options<WaitlistEntriesData>,
	) => Promise<WaitlistEntriesResponse2>;
	updateEntry?: (
		options: Options<WaitlistUpdateEntryData>,
	) => Promise<WaitlistUpdateEntryResponse>;
	restoreEntry?: (
		options: Options<WaitlistRestoreEntryData>,
	) => Promise<WaitlistRestoreEntryResponse>;
	/** The page's people by entry id: credit and offered commands (ALE-417). */
	listPeople?: (waitlistIds: string[]) => Promise<BeginnersWorkshopPeople>;
	/** ALE-389: the Carried Fee panel's requests, when a person's fee is managed. */
	carriedFee?: CarriedFeePanelDeps;
	/** Defaults to svelte-sonner's `toast`. */
	notify?: WaitlistNotify;
	/** URL source and navigation for the cursor-table URL state. */
	url?: () => URL;
	navigate?: CursorTableNavigate;
};

/** A row command: the Waitlist entry's own, or a Beginners' Workshop person command. */
export type WaitlistRowCommand =
	| WaitlistEntryCommand
	| BeginnersWorkshopPersonCommand;

/** Prefix shared by every Waitlist page's query key. */
const allWaitlistPages = () => waitlistEntriesQueryKey();

// Every person read, whatever its ids. Generated keys are
// `[{ _id: "<operation id>", … }]`, and TanStack matches a partial key.
const allPeople = [{ _id: "beginnersWorkshopPeopleIndex" }];

/** Restore changes the page and its people. */
function invalidatePageAndPeople(queryClient: QueryClient) {
	return Promise.all([
		queryClient.invalidateQueries({ queryKey: allWaitlistPages() }),
		queryClient.invalidateQueries({ queryKey: allPeople }),
	]);
}

export function createWaitlistTable(deps: WaitlistTableDeps = {}) {
	const queryClient = deps.queryClient ?? useQueryClient();
	const notify = deps.notify ?? toast;

	// Column ids are the API sort names, so the URL `sort` param is one too.
	const url = createCursorTableUrl({
		sort: {
			fields: {
				position: "position",
				fullName: "fullName",
				status: "status",
				age: "age",
				initialRegistrationDate: "initialRegistrationDate",
				lastContacted: "lastContacted",
				lastStatusChange: "lastStatusChange",
			},
			default: "position",
		},
		filters: ["status"],
		url: deps.url,
		navigate: deps.navigate,
	});

	// An absent or unknown `status` param is the queue.
	const standing = $derived.by((): WaitlistStanding => {
		const requested = url.filter("status");
		return isStanding(requested) ? requested : DEFAULT_STANDING;
	});

	const query = createQuery(
		() => {
			const requestOptions = { query: { ...url.request, status: standing } };
			const options = waitlistEntriesOptions(requestOptions);
			const listEntries = deps.listEntries;
			if (listEntries) options.queryFn = () => listEntries(requestOptions);
			return { ...options, placeholderData: keepPreviousData };
		},
		() => queryClient,
	);

	const pageIds = $derived(
		(query.data?.data.entries ?? []).map((entry) => entry.id),
	);

	const people = createQuery(
		() => {
			const waitlistIds = pageIds.join(",");
			const options = beginnersWorkshopPeopleIndexOptions({
				query: { waitlistIds },
			});
			const listPeople = deps.listPeople;
			const ids = pageIds;
			return {
				...options,
				...(listPeople && {
					queryFn: async () => ({ data: await listPeople(ids) }),
				}),
				select: (response: { data: BeginnersWorkshopPeople }) => response.data,
				enabled: ids.length > 0,
			};
		},
		() => queryClient,
	);

	const updateWaitlistEntry = createMutation(
		() => {
			const options = waitlistUpdateEntryMutation();
			const request = deps.updateEntry;
			if (request) options.mutationFn = (vars) => request(vars);
			return {
				...options,
				onSuccess: () => {
					notify.success("Details updated.");
				},
				onError: () => {
					notify.error("Could not update their details.");
				},
				onSettled: () =>
					queryClient.invalidateQueries({ queryKey: allWaitlistPages() }),
			};
		},
		() => queryClient,
	);

	const restoreWaitlistEntry = createMutation(
		() => {
			const options = waitlistRestoreEntryMutation();
			const request = deps.restoreEntry;
			if (request) options.mutationFn = (vars) => request(vars);
			return {
				...options,
				onSuccess: () => {
					notify.success("Restored to the Waitlist with their original date.");
				},
				onError: (error) => {
					notify.error(
						apiProblem(error)?.detail ?? "Could not restore this person.",
					);
				},
				onSettled: () => invalidatePageAndPeople(queryClient),
			};
		},
		() => queryClient,
	);

	return {
		/** URL-backed search, page size, cursor paging and table sort state. */
		url,
		/** The standing being listed: `waiting` (default) or `removed`. */
		get standing() {
			return standing;
		},
		/** Lists another standing; the queue is written as no filter. */
		setStanding(next: WaitlistStanding) {
			url.setFilter("status", next === DEFAULT_STANDING ? null : next);
		},
		get entries(): WaitlistEntry[] {
			return query.data?.data.entries ?? [];
		},
		get count() {
			return query.data?.data.totalCount ?? 0;
		},
		get nextCursor() {
			return query.data?.data.nextCursor ?? null;
		},
		get previousCursor() {
			return query.data?.data.previousCursor ?? null;
		},
		get isFetching() {
			return query.isFetching;
		},
		/** The person's live Carried Fee status, or `null` without one (or until known). */
		carriedFee(id: string): BeginnersCarriedFeeStatus | null {
			return people.data?.[id]?.carriedFee ?? null;
		},
		/**
		 * The money an offered Withdraw or Delete must settle by refund or
		 * forfeit (Phoenix's `refundChoice`), or `null` without (or until known).
		 */
		refundChoice(id: string): BeginnersWorkshopRefundChoice | null {
			return people.data?.[id]?.refundChoice ?? null;
		},
		/**
		 * Whether Phoenix offers `command` on this row: the entry's own
		 * commands and the person's, merged (a person command is not offered
		 * until the person read answers). Advisory — Phoenix decides again.
		 */
		offers(entry: WaitlistEntry, command: WaitlistRowCommand): boolean {
			const offered: readonly WaitlistRowCommand[] = [
				...entry.availableCommands,
				...(people.data?.[entry.id]?.availableCommands ?? []),
			];
			return offered.includes(command);
		},
		/** Saves the entry's admin notes, the only editable Waitlist field. */
		updateAdminNotes(id: string, adminNotes: string | null) {
			updateWaitlistEntry.mutate({ path: { id }, body: { adminNotes } });
		},
		get isUpdating() {
			return updateWaitlistEntry.isPending;
		},
		/** Moves a removed person back to `waiting` with their original date. */
		restore(id: string) {
			restoreWaitlistEntry.mutate({ path: { id } });
		},
		get isRestoring() {
			return restoreWaitlistEntry.isPending;
		},
	};
}

export type WaitlistTable = ReturnType<typeof createWaitlistTable>;
