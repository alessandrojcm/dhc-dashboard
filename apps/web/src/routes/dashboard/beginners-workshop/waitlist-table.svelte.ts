/**
 * The beginners' waitlist table: one interface for reading a page of Waitlist
 * entries and for every action the desktop table and the mobile cards offer.
 *
 * The controller owns the Waitlist Status decision for a single invitation
 * (`sendInvitation`), the optimistic `invited` marking across every cached
 * Waitlist page with rollback on error, cache invalidation, selection, and
 * the toasts each action raises. Markup only renders and calls these actions.
 */
import {
	invitationsCreateMutation,
	invitationsResendMutation,
	waitlistEntriesOptions,
	waitlistEntriesQueryKey,
	waitlistUpdateEntryMutation,
	type InvitationsCreateData,
	type InvitationsCreateResponse,
	type InvitationsResendData,
	type InvitationsResendResponse,
	type Options,
	type WaitlistEntriesData,
	type WaitlistEntriesResponse2,
	type WaitlistEntry,
	type WaitlistEntryUpdateRequest,
	type WaitlistStatus,
	type WaitlistUpdateEntryData,
	type WaitlistUpdateEntryResponse,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	keepPreviousData,
	useQueryClient,
	type QueryClient,
	type QueryKey,
} from "@tanstack/svelte-query";
import type { RowSelectionState, Updater } from "@tanstack/table-core";
import { toast } from "svelte-sonner";
import * as v from "valibot";
import {
	createCursorTableUrl,
	type CursorTableNavigate,
} from "#lib/cursor-table-url.svelte.js";

export type WaitlistNotify = {
	success(message: string): void;
	error(message: string): void;
};

export type WaitlistTableDeps = {
	/** Defaults to the query client from context. */
	queryClient?: QueryClient;
	/** Request functions; each defaults to the generated `@dhc/api-client` call. */
	listEntries?: (
		options: Options<WaitlistEntriesData>,
	) => Promise<WaitlistEntriesResponse2>;
	createInvitations?: (
		options: Options<InvitationsCreateData>,
	) => Promise<InvitationsCreateResponse>;
	resendInvitations?: (
		options: Options<InvitationsResendData>,
	) => Promise<InvitationsResendResponse>;
	updateEntry?: (
		options: Options<WaitlistUpdateEntryData>,
	) => Promise<WaitlistUpdateEntryResponse>;
	/** Defaults to svelte-sonner's `toast`. */
	notify?: WaitlistNotify;
	/** URL source and navigation for the cursor-table URL state. */
	url?: () => URL;
	navigate?: CursorTableNavigate;
};

type Snapshot = Array<[QueryKey, WaitlistEntriesResponse2 | undefined]>;

/** Prefix shared by every Waitlist page's query key. */
const allWaitlistPages = () => waitlistEntriesQueryKey();

function getEntryIds(options: Options<InvitationsCreateData>) {
	return options.body.invites.flatMap((invite) => {
		const parsed = v.safeParse(v.string(), invite);
		return parsed.success ? [parsed.output] : [];
	});
}

function resolve<T>(updater: Updater<T>, current: T): T {
	return updater instanceof Function ? updater(current) : updater;
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
		url: deps.url,
		navigate: deps.navigate,
	});

	let selection = $state<RowSelectionState>({});
	const selectedIds = $derived(
		Object.entries(selection).flatMap(([id, selected]) =>
			selected ? [id] : [],
		),
	);

	const query = createQuery(
		() => {
			const requestOptions = { query: url.request };
			const options = waitlistEntriesOptions(requestOptions);
			const listEntries = deps.listEntries;
			if (listEntries) options.queryFn = () => listEntries(requestOptions);
			return { ...options, placeholderData: keepPreviousData };
		},
		() => queryClient,
	);

	/** Marks matching entries `invited` on every cached page; returns the rollback snapshot. */
	async function markInvited(
		matches: (entry: WaitlistEntry) => boolean,
	): Promise<{ snapshot: Snapshot }> {
		await queryClient.cancelQueries({ queryKey: allWaitlistPages() });
		const snapshot: Snapshot =
			queryClient.getQueriesData<WaitlistEntriesResponse2>({
				queryKey: allWaitlistPages(),
			});
		queryClient.setQueriesData<WaitlistEntriesResponse2>(
			{ queryKey: allWaitlistPages() },
			(old) =>
				old && {
					...old,
					data: {
						...old.data,
						entries: old.data.entries.map((entry) =>
							matches(entry) ? { ...entry, status: "invited" } : entry,
						),
					},
				},
		);
		return { snapshot };
	}

	function rollback(context: { snapshot: Snapshot } | undefined) {
		for (const [key, data] of context?.snapshot ?? []) {
			queryClient.setQueryData(key, data);
		}
	}

	function invalidateWaitlist() {
		return queryClient.invalidateQueries({ queryKey: allWaitlistPages() });
	}

	const createInvitation = createMutation(
		() => {
			const options = invitationsCreateMutation();
			const request = deps.createInvitations;
			if (request) options.mutationFn = (vars) => request(vars);
			return {
				...options,
				onMutate: (vars) => {
					const ids = getEntryIds(vars);
					return markInvited((entry) => ids.includes(entry.id));
				},
				onSuccess: (_data, vars) => {
					// Invited entries leave the selection; a bulk invite empties it.
					const invited = getEntryIds(vars);
					selection = Object.fromEntries(
						Object.entries(selection).filter(([id]) => !invited.includes(id)),
					);
					notify.success("Invitations are being processed in the background.");
				},
				onError: (_error, _vars, context) => {
					rollback(context);
					notify.error("Something has gone wrong inviting members.");
				},
				onSettled: invalidateWaitlist,
			};
		},
		() => queryClient,
	);

	const resendInvitation = createMutation(
		() => {
			const options = invitationsResendMutation();
			const request = deps.resendInvitations;
			if (request) options.mutationFn = (vars) => request(vars);
			return {
				...options,
				onMutate: (vars) => {
					const emails = vars.body.emails;
					return markInvited((entry) => emails.includes(entry.email));
				},
				onSuccess: () => {
					notify.success("Invitation link resent.");
				},
				onError: (_error, _vars, context) => {
					rollback(context);
					notify.error("Something has gone wrong inviting members.");
				},
				onSettled: invalidateWaitlist,
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
					notify.success("Waitlist entry updated.");
				},
				onError: () => {
					notify.error("Failed to update waitlist entry.");
				},
				onSettled: invalidateWaitlist,
			};
		},
		() => queryClient,
	);

	return {
		/** URL-backed search, page size, cursor paging and table sort state. */
		url,
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
		get selection() {
			return selection;
		},
		setSelection(updater: Updater<RowSelectionState>) {
			selection = resolve(updater, selection);
		},
		get selectedIds() {
			return selectedIds;
		},
		/** Bulk: creates an Invitation for each Waitlist entry id. */
		invite(entryIds: string[]) {
			if (entryIds.length === 0) return;
			createInvitation.mutate({ body: { invites: entryIds } });
		},
		/** Invites a non-`invited` entry by id; resends an `invited` entry's link by email. */
		sendInvitation(entry: WaitlistEntry) {
			if (entry.status === "invited") {
				resendInvitation.mutate({ body: { emails: [entry.email] } });
			} else {
				createInvitation.mutate({ body: { invites: [entry.id] } });
			}
		},
		updateEntry(id: string, patch: WaitlistEntryUpdateRequest) {
			updateWaitlistEntry.mutate({ path: { id }, body: patch });
		},
		/** Changes an entry's Waitlist Status; choosing its current status is a no-op. */
		setStatus(entry: WaitlistEntry, status: WaitlistStatus) {
			if (status === entry.status) return;
			updateWaitlistEntry.mutate({ path: { id: entry.id }, body: { status } });
		},
		get isInviting() {
			return createInvitation.isPending;
		},
		get isResending() {
			return resendInvitation.isPending;
		},
		get isUpdating() {
			return updateWaitlistEntry.isPending;
		},
	};
}

export type WaitlistTable = ReturnType<typeof createWaitlistTable>;
