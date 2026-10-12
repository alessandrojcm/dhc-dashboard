/**
 * The beginners' Waitlist table: one interface for reading a page of Waitlist
 * entries and for every action the desktop table and the mobile cards offer.
 *
 * The Waitlist view is the queue: it lists `waiting` people by default, with
 * `removed` people behind the standing filter (ALE-375). Waitlist Status is
 * not editable here — it changes only through named commands — so the
 * writes are the entry's admin notes and `restore` (ALE-376), which returns a
 * removed person to the queue with their original date. Withdraw (ALE-387)
 * is the Beginners' Workshop boundary's command, not the Waitlist's — it may
 * close the person's open Intake — so it calls Phoenix's
 * `beginnersWorkshopIntakes.withdrawPerson`. Delete (ALE-396) is the
 * boundary's hard delete too (`beginnersWorkshopIntakes.deletePerson`): it
 * anonymises the person's Intakes and settles their Carried Fee.
 * Which of these a row offers is Phoenix's (ALE-417), never worked out
 * here: Restore from the entry's own `availableCommands` (the Waitlist's
 * retention rule), Withdraw and Delete — and each person's workshop credit
 * status — from Beginners' Workshops' person read
 * (`beginnersWorkshopPeople.index`), one extra query over the page's ids,
 * because the Waitlist API cannot know them. `offers` merges both lists.
 * The controller owns
 * the URL-backed list request, cache invalidation and the toasts; markup only
 * renders and calls these actions.
 */
import {
	beginnersWorkshopPeopleIndexOptions,
	type BeginnersCarriedFeeStatus,
	type BeginnersWorkshopDeletePersonRequest,
	beginnersWorkshopIntakesDeletePersonMutation,
	type BeginnersWorkshopIntakesDeletePersonData,
	type BeginnersWorkshopIntakesDeletePersonResponse,
	beginnersWorkshopIntakesWithdrawPersonMutation,
	type BeginnersWorkshopIntakesWithdrawPersonData,
	type BeginnersWorkshopIntakesWithdrawPersonResponse,
	type BeginnersWorkshopPeople,
	type BeginnersWorkshopPersonCommand,
	type BeginnersWorkshopWithdrawRequest,
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
	withdrawEntry?: (
		options: Options<BeginnersWorkshopIntakesWithdrawPersonData>,
	) => Promise<BeginnersWorkshopIntakesWithdrawPersonResponse>;
	deleteEntry?: (
		options: Options<BeginnersWorkshopIntakesDeletePersonData>,
	) => Promise<BeginnersWorkshopIntakesDeletePersonResponse>;
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

/** The outcome of a Withdraw or Delete: done, or Phoenix's reason and its code. */
export type WithdrawOutcome =
	| { ok: true }
	| { ok: false; error: string; code: string | null };

/** Prefix shared by every Waitlist page's query key. */
const allWaitlistPages = () => waitlistEntriesQueryKey();

// Every person read, whatever its ids. Generated keys are
// `[{ _id: "<operation id>", … }]`, and TanStack matches a partial key.
const allPeople = [{ _id: "beginnersWorkshopPeopleIndex" }];

/** A person command or Restore changes the page and its people. */
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

	const withdrawWaitlistEntry = createMutation(
		() => {
			const options = beginnersWorkshopIntakesWithdrawPersonMutation();
			const request = deps.withdrawEntry;
			if (request) options.mutationFn = (vars) => request(vars);
			return {
				...options,
				onSuccess: () => {
					notify.success("Withdrawn from the Waitlist.");
				},
				onSettled: () => invalidatePageAndPeople(queryClient),
			};
		},
		() => queryClient,
	);

	const deleteWaitlistEntry = createMutation(
		() => {
			const options = beginnersWorkshopIntakesDeletePersonMutation();
			const request = deps.deleteEntry;
			if (request) options.mutationFn = (vars) => request(vars);
			return {
				...options,
				onSuccess: () => {
					notify.success(
						"Deleted. Their workshop places stay in the reports, anonymised.",
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
		/**
		 * Withdraws the person from the Waitlist (ALE-387). The dialog shows a
		 * refusal itself — `refund_choice_required` under the refund choice —
		 * so the outcome is returned rather than toasted.
		 */
		async withdraw(
			id: string,
			body: BeginnersWorkshopWithdrawRequest,
		): Promise<WithdrawOutcome> {
			try {
				await withdrawWaitlistEntry.mutateAsync({
					path: { waitlistId: id },
					body,
				});
				return { ok: true };
			} catch (error) {
				const problem = apiProblem(error);
				return {
					ok: false,
					error: problem?.detail ?? "Could not withdraw this person.",
					code: problem?.code ?? null,
				};
			}
		},
		get isWithdrawing() {
			return withdrawWaitlistEntry.isPending;
		},
		/**
		 * Deletes the person (ALE-396). Like Withdraw, the dialog shows a
		 * refusal itself (`refund_choice_required` under the refund choice).
		 */
		async deletePerson(
			id: string,
			body: BeginnersWorkshopDeletePersonRequest,
		): Promise<WithdrawOutcome> {
			try {
				await deleteWaitlistEntry.mutateAsync({
					path: { waitlistId: id },
					body,
				});
				return { ok: true };
			} catch (error) {
				const problem = apiProblem(error);
				return {
					ok: false,
					error: problem?.detail ?? "Could not delete this person.",
					code: problem?.code ?? null,
				};
			}
		},
		get isDeleting() {
			return deleteWaitlistEntry.isPending;
		},
	};
}

export type WaitlistTable = ReturnType<typeof createWaitlistTable>;
