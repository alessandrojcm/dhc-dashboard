import {
	waitlistEntriesQueryKey,
	type InvitationsCreateResponse,
	type InvitationsResendResponse,
	type WaitlistEntriesResponse2,
	type WaitlistEntry,
	type WaitlistUpdateEntryResponse,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
	createWaitlistTable,
	type WaitlistTableDeps,
} from "./waitlist-table.svelte.js";

const BASE = "https://dhc.test/dashboard/beginners-workshop";

function entry(
	id: string,
	overrides: Partial<WaitlistEntry> = {},
): WaitlistEntry {
	return {
		id,
		position: 1,
		fullName: `Person ${id}`,
		email: `${id}@test.com`,
		phoneNumber: "0840000000",
		status: "waiting",
		age: 25,
		initialRegistrationDate: "2026-01-01T00:00:00Z",
		lastContacted: null,
		lastStatusChange: "2026-01-01T00:00:00Z",
		insuranceFormSubmitted: false,
		adminNotes: null,
		socialMediaConsent: "no",
		medicalConditions: null,
		guardianFirstName: null,
		guardianLastName: null,
		guardianPhoneNumber: null,
		...overrides,
	};
}

function page(entries: WaitlistEntry[]): WaitlistEntriesResponse2 {
	return {
		data: {
			entries,
			totalCount: entries.length,
			limit: 10,
			nextCursor: null,
			previousCursor: null,
		},
	};
}

function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((res) => {
		resolve = res;
	});
	return { promise, resolve };
}

const firstPageKey = waitlistEntriesQueryKey({
	query: { limit: 10, sort: "position", direction: "asc" },
});
const otherPageKey = waitlistEntriesQueryKey({
	query: { limit: 10, sort: "position", direction: "asc", cursor: "c2" },
});

const cleanups: Array<() => void> = [];

afterEach(() => {
	while (cleanups.length) cleanups.pop()?.();
});

function setup(
	firstPage: WaitlistEntry[],
	deps: Partial<WaitlistTableDeps> = {},
) {
	const queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false, staleTime: Infinity },
			mutations: { retry: false },
		},
	});
	queryClient.setQueryData(firstPageKey, page(firstPage));
	const notify = { success: vi.fn(), error: vi.fn() };
	const listEntries = vi.fn(async () => page(firstPage));
	const createInvitations = vi.fn(
		async (): Promise<InvitationsCreateResponse> => ({}),
	);
	const resendInvitations = vi.fn(
		async (): Promise<InvitationsResendResponse> => ({}),
	);
	const updateEntry = vi.fn(
		async (): Promise<WaitlistUpdateEntryResponse> => ({
			data: entry("updated"),
		}),
	);
	const url = new URL(BASE);

	let table!: ReturnType<typeof createWaitlistTable>;
	cleanups.push(
		$effect.root(() => {
			table = createWaitlistTable({
				queryClient,
				notify,
				listEntries,
				createInvitations,
				resendInvitations,
				updateEntry,
				url: () => url,
				navigate: () => {},
				...deps,
			});
		}),
	);

	return {
		table,
		queryClient,
		notify,
		listEntries,
		createInvitations,
		resendInvitations,
		updateEntry,
	};
}

function statusIn(queryClient: QueryClient, key: unknown[], id: string) {
	const data = queryClient.getQueryData<WaitlistEntriesResponse2>(key);
	return data?.data.entries.find((candidate) => candidate.id === id)?.status;
}

describe("createWaitlistTable", () => {
	it("exposes the cached page as entries and count", async () => {
		const { table } = setup([entry("a"), entry("b")]);

		await expect.poll(() => table.entries.map((e) => e.id)).toEqual(["a", "b"]);
		expect(table.count).toBe(2);
		expect(table.nextCursor).toBeNull();
	});

	it("marks invited entries optimistically and invalidates every waitlist page on settle", async () => {
		const request = deferred<InvitationsCreateResponse>();
		const createInvitations = vi.fn(() => request.promise);
		const { table, queryClient, notify, listEntries } = setup(
			[entry("a"), entry("b")],
			{ createInvitations },
		);
		queryClient.setQueryData(otherPageKey, page([entry("c")]));

		table.invite(["a", "c"]);

		await expect
			.poll(() => statusIn(queryClient, firstPageKey, "a"))
			.toBe("invited");
		expect(statusIn(queryClient, firstPageKey, "b")).toBe("waiting");
		expect(statusIn(queryClient, otherPageKey, "c")).toBe("invited");
		expect(table.isInviting).toBe(true);
		expect(createInvitations).toHaveBeenCalledWith(
			expect.objectContaining({ body: { invites: ["a", "c"] } }),
		);

		request.resolve({});

		await expect
			.poll(() => queryClient.getQueryState(otherPageKey)?.isInvalidated)
			.toBe(true);
		// The page on screen is active, so invalidating it refetches it.
		await expect.poll(() => listEntries.mock.calls.length).toBe(1);
		expect(notify.success).toHaveBeenCalledWith(
			"Invitations are being processed in the background.",
		);
		expect(table.isInviting).toBe(false);
	});

	it("rolls back every page when the invite fails", async () => {
		const createInvitations = vi.fn(async () => {
			throw new Error("boom");
		});
		const { table, queryClient, notify } = setup([entry("a")], {
			createInvitations,
		});
		queryClient.setQueryData(otherPageKey, page([entry("c")]));

		table.invite(["a", "c"]);

		await expect.poll(() => notify.error.mock.calls.length).toBe(1);
		expect(notify.error).toHaveBeenCalledWith(
			"Something has gone wrong inviting members.",
		);
		expect(statusIn(queryClient, firstPageKey, "a")).toBe("waiting");
		expect(statusIn(queryClient, otherPageKey, "c")).toBe("waiting");
		await expect
			.poll(() => queryClient.getQueryState(otherPageKey)?.isInvalidated)
			.toBe(true);
		expect(notify.success).not.toHaveBeenCalled();
	});

	it("clears the selection after a successful bulk invite", async () => {
		const { table, notify } = setup([entry("a"), entry("b")]);
		table.setSelection({ a: true, b: true });
		expect(table.selectedIds).toEqual(["a", "b"]);

		table.invite(table.selectedIds);

		await expect.poll(() => notify.success.mock.calls.length).toBe(1);
		expect(table.selectedIds).toEqual([]);
	});

	it("keeps the selection when the bulk invite fails", async () => {
		const { table, notify } = setup([entry("a")], {
			createInvitations: vi.fn(async () => {
				throw new Error("boom");
			}),
		});
		table.setSelection({ a: true });

		table.invite(table.selectedIds);

		await expect.poll(() => notify.error.mock.calls.length).toBe(1);
		expect(table.selectedIds).toEqual(["a"]);
	});

	it("creates an Invitation by entry id for an entry that is not invited", async () => {
		const { table, createInvitations, resendInvitations, notify } = setup([
			entry("a"),
		]);

		table.sendInvitation(entry("a", { status: "deferred" }));

		await expect.poll(() => notify.success.mock.calls.length).toBe(1);
		expect(createInvitations).toHaveBeenCalledWith(
			expect.objectContaining({ body: { invites: ["a"] } }),
		);
		expect(resendInvitations).not.toHaveBeenCalled();
	});

	it("resends by email for an invited entry", async () => {
		const request = deferred<InvitationsResendResponse>();
		const resendInvitations = vi.fn(() => request.promise);
		const invited = entry("a", { status: "invited" });
		const { table, createInvitations, notify, listEntries } = setup([invited], {
			resendInvitations,
		});

		table.sendInvitation(invited);

		await expect.poll(() => table.isResending).toBe(true);
		expect(resendInvitations).toHaveBeenCalledWith(
			expect.objectContaining({ body: { emails: ["a@test.com"] } }),
		);
		expect(createInvitations).not.toHaveBeenCalled();

		request.resolve({});

		await expect.poll(() => notify.success.mock.calls.length).toBe(1);
		expect(notify.success).toHaveBeenCalledWith("Invitation link resent.");
		await expect.poll(() => listEntries.mock.calls.length).toBe(1);
	});

	it("rolls back a failed resend", async () => {
		const resendInvitations = vi.fn(async () => {
			throw new Error("boom");
		});
		const { table, queryClient, notify } = setup(
			[entry("a"), entry("b", { status: "invited", email: "b@test.com" })],
			{ resendInvitations },
		);
		queryClient.setQueryData(
			otherPageKey,
			page([entry("c", { email: "b@test.com" })]),
		);

		table.sendInvitation(entry("b", { status: "invited" }));

		await expect.poll(() => notify.error.mock.calls.length).toBe(1);
		expect(statusIn(queryClient, otherPageKey, "c")).toBe("waiting");
		expect(statusIn(queryClient, firstPageKey, "b")).toBe("invited");
	});

	it("updates an entry, notifies, and invalidates the waitlist once", async () => {
		const { table, queryClient, updateEntry, notify } = setup([entry("a")]);
		const invalidate = vi.spyOn(queryClient, "invalidateQueries");

		table.updateEntry("a", { adminNotes: "Called twice" });

		await expect.poll(() => notify.success.mock.calls.length).toBe(1);
		expect(notify.success).toHaveBeenCalledWith("Waitlist entry updated.");
		expect(updateEntry).toHaveBeenCalledWith(
			expect.objectContaining({
				path: { id: "a" },
				body: { adminNotes: "Called twice" },
			}),
		);
		await expect.poll(() => invalidate.mock.calls.length).toBe(1);
		expect(invalidate).toHaveBeenCalledWith({
			queryKey: waitlistEntriesQueryKey(),
		});
		expect(table.isUpdating).toBe(false);
	});

	it("sets a changed status and skips a no-op status change", async () => {
		const { table, updateEntry, notify } = setup([entry("a")]);

		table.setStatus(entry("a", { status: "waiting" }), "waiting");
		table.setStatus(entry("a", { status: "waiting" }), "deferred");

		await expect.poll(() => notify.success.mock.calls.length).toBe(1);
		expect(updateEntry).toHaveBeenCalledOnce();
		expect(updateEntry).toHaveBeenCalledWith(
			expect.objectContaining({
				path: { id: "a" },
				body: { status: "deferred" },
			}),
		);
	});

	it("notifies a failed update and still invalidates once", async () => {
		const { table, queryClient, notify } = setup([entry("a")], {
			updateEntry: vi.fn(async () => {
				throw new Error("boom");
			}),
		});
		const invalidate = vi.spyOn(queryClient, "invalidateQueries");

		table.updateEntry("a", { status: "deferred" });

		await expect.poll(() => notify.error.mock.calls.length).toBe(1);
		expect(notify.error).toHaveBeenCalledWith(
			"Failed to update waitlist entry.",
		);
		await expect.poll(() => invalidate.mock.calls.length).toBe(1);
		expect(notify.success).not.toHaveBeenCalled();
	});
});
