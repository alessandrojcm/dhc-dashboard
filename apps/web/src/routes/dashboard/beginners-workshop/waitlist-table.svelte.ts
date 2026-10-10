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
 * `beginnersWorkshopIntakes.withdrawPerson`. The controller owns
 * the URL-backed list request, cache invalidation and the toasts; markup only
 * renders and calls these actions.
 */
import {
	beginnersWorkshopIntakesWithdrawPersonMutation,
	type BeginnersWorkshopIntakesWithdrawPersonData,
	type BeginnersWorkshopIntakesWithdrawPersonResponse,
	type BeginnersWorkshopWithdrawRequest,
	waitlistEntriesOptions,
	waitlistEntriesQueryKey,
	waitlistRestoreEntryMutation,
	waitlistUpdateEntryMutation,
	type Options,
	type WaitlistEntriesData,
	type WaitlistEntriesResponse2,
	type WaitlistEntry,
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
import dayjs from "dayjs";
import { toast } from "svelte-sonner";
import { apiProblem } from "#lib/api-error.js";
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
	withdrawEntry?: (
		options: Options<BeginnersWorkshopIntakesWithdrawPersonData>,
	) => Promise<BeginnersWorkshopIntakesWithdrawPersonResponse>;
	/** Defaults to the current time; decides which removed people are offered restore. */
	now?: () => Date;
	/** Defaults to svelte-sonner's `toast`. */
	notify?: WaitlistNotify;
	/** URL source and navigation for the cursor-table URL state. */
	url?: () => URL;
	navigate?: CursorTableNavigate;
};

/** Phoenix restores a removed person within this many calendar months. */
export const RESTORE_WINDOW_MONTHS = 3;

/**
 * Whether restore is offered for `entry`: removed within the restore window.
 * Advisory only — Phoenix decides and answers `restore_window_passed`.
 */
export function canRestore(entry: WaitlistEntry, now: Date): boolean {
	if (entry.status !== "removed" || !entry.removedAt) return false;
	return !dayjs(now).isAfter(
		dayjs(entry.removedAt).add(RESTORE_WINDOW_MONTHS, "month"),
	);
}

/**
 * Whether Withdraw is offered for `entry` (ALE-387): someone still on the
 * Waitlist — waiting (with or without an open Intake) or attended and not
 * yet invited. Advisory only — Phoenix decides (`already_invited`).
 */
export function canWithdraw(entry: WaitlistEntry): boolean {
	return entry.status === "waiting" || entry.status === "attended";
}

/** The outcome of a Withdraw: done, or Phoenix's reason and its code. */
export type WithdrawOutcome =
	| { ok: true }
	| { ok: false; error: string; code: string | null };

/** Prefix shared by every Waitlist page's query key. */
const allWaitlistPages = () => waitlistEntriesQueryKey();

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

	const updateWaitlistEntry = createMutation(
		() => {
			const options = waitlistUpdateEntryMutation();
			const request = deps.updateEntry;
			if (request) options.mutationFn = (vars) => request(vars);
			return {
				...options,
				onSuccess: () => {
					notify.success("Waitlist entry updated.");
				},
				onError: () => {
					notify.error("Failed to update waitlist entry.");
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
						apiProblem(error)?.detail ?? "Failed to restore waitlist entry.",
					);
				},
				onSettled: () =>
					queryClient.invalidateQueries({ queryKey: allWaitlistPages() }),
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
				onSettled: () =>
					queryClient.invalidateQueries({ queryKey: allWaitlistPages() }),
			};
		},
		() => queryClient,
	);

	const now = deps.now ?? (() => new Date());

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
		/** Saves the entry's admin notes, the only editable Waitlist field. */
		updateAdminNotes(id: string, adminNotes: string | null) {
			updateWaitlistEntry.mutate({ path: { id }, body: { adminNotes } });
		},
		get isUpdating() {
			return updateWaitlistEntry.isPending;
		},
		/** Whether restore is offered for this entry (removed within 3 months). */
		canRestore(entry: WaitlistEntry) {
			return canRestore(entry, now());
		},
		/** Moves a removed person back to `waiting` with their original date. */
		restore(id: string) {
			restoreWaitlistEntry.mutate({ path: { id } });
		},
		get isRestoring() {
			return restoreWaitlistEntry.isPending;
		},
		/** Whether Withdraw is offered for this entry. */
		canWithdraw(entry: WaitlistEntry) {
			return canWithdraw(entry);
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
	};
}

export type WaitlistTable = ReturnType<typeof createWaitlistTable>;
