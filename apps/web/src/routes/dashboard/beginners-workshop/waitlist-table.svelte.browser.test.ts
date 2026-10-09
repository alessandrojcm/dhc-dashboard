import {
	waitlistEntriesQueryKey,
	type Options,
	type WaitlistEntriesData,
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
		removedAt: null,
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

const firstPageKey = waitlistEntriesQueryKey({
	query: { limit: 10, sort: "position", direction: "asc", status: "waiting" },
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
	const updateEntry = vi.fn(
		async (): Promise<WaitlistUpdateEntryResponse> => ({
			data: entry("updated"),
		}),
	);
	// Reassigned by `navigate`, so the URL-backed request reacts like a page.
	let url = $state(new URL(deps.url?.() ?? BASE));
	const navigate = vi.fn((href: string) => {
		url = new URL(href, BASE);
	});

	let table!: ReturnType<typeof createWaitlistTable>;
	cleanups.push(
		$effect.root(() => {
			table = createWaitlistTable({
				queryClient,
				notify,
				listEntries,
				updateEntry,
				navigate,
				...deps,
				url: () => url,
			});
		}),
	);

	return {
		table,
		queryClient,
		notify,
		listEntries,
		updateEntry,
		navigate,
	};
}

describe("createWaitlistTable", () => {
	it("exposes the cached page as entries and count", async () => {
		const { table } = setup([entry("a"), entry("b")]);

		await expect.poll(() => table.entries.map((e) => e.id)).toEqual(["a", "b"]);
		expect(table.count).toBe(2);
		expect(table.nextCursor).toBeNull();
	});

	it("lists the waiting queue by default", () => {
		const { table } = setup([entry("a")]);

		expect(table.standing).toBe("waiting");
	});

	it("lists removed people behind the standing filter", async () => {
		const removed = entry("r", {
			status: "removed",
			removedAt: "2026-02-01T00:00:00Z",
		});
		const listEntries = vi.fn(async (_options: Options<WaitlistEntriesData>) =>
			page([removed]),
		);
		const { table, navigate } = setup([entry("a")], { listEntries });

		table.setStanding("removed");

		expect(navigate).toHaveBeenCalledWith(
			expect.stringContaining("status=removed"),
			{ replace: true },
		);
		await expect.poll(() => table.standing).toBe("removed");
		await expect
			.poll(() => listEntries.mock.calls.at(-1)?.[0])
			.toEqual(
				expect.objectContaining({
					query: expect.objectContaining({ status: "removed" }),
				}),
			);
		await expect.poll(() => table.entries.map((e) => e.id)).toEqual(["r"]);

		table.setStanding("waiting");

		// The queue is the default, so it is written as no filter.
		expect(navigate.mock.calls.at(-1)?.[0]).not.toContain("status=");
		await expect.poll(() => table.standing).toBe("waiting");
	});

	it("treats an unknown standing in the URL as the queue", () => {
		const { table } = setup([entry("a")], {
			url: () => new URL(`${BASE}?status=joined`),
		});

		expect(table.standing).toBe("waiting");
	});

	it("saves admin notes, notifies, and invalidates the waitlist once", async () => {
		const { table, queryClient, updateEntry, notify } = setup([entry("a")]);
		const invalidate = vi.spyOn(queryClient, "invalidateQueries");

		table.updateAdminNotes("a", "Called twice");

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

	it("notifies a failed update and still invalidates once", async () => {
		const { table, queryClient, notify } = setup([entry("a")], {
			updateEntry: vi.fn(async () => {
				throw new Error("boom");
			}),
		});
		const invalidate = vi.spyOn(queryClient, "invalidateQueries");

		table.updateAdminNotes("a", null);

		await expect.poll(() => notify.error.mock.calls.length).toBe(1);
		expect(notify.error).toHaveBeenCalledWith(
			"Failed to update waitlist entry.",
		);
		await expect.poll(() => invalidate.mock.calls.length).toBe(1);
		expect(notify.success).not.toHaveBeenCalled();
	});
});
