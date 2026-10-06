import {
	inventoryCatalogListItemsQueryKey,
	inventoryCatalogShowItemQueryKey,
	inventoryMemberLoansListQueryKey,
	inventoryMemberLoansShowQueryKey,
	inventoryOperatorLoanQueueShowQueryKey,
	type InventoryMemberLoan,
} from "@dhc/api-client";
import { MutationObserver, QueryClient } from "@tanstack/svelte-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
	availabilityLabel,
	cancelLoanOptions,
	defaultLoanDates,
	loanStatusLabel,
	memberLoanErrorMessage,
	requestLoanOptions,
	type CancelLoanFn,
	type RequestLoanFn,
} from "./member-loans.svelte.js";

const notify = { success: vi.fn(), error: vi.fn() };

const slug = "item-000042";
const loanId = "cccccccc-cccc-cccc-cccc-cccccccccccc";

function loan(status: InventoryMemberLoan["status"]): InventoryMemberLoan {
	return {
		id: loanId,
		itemId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
		status,
		overdue: false,
		cancellable: status === "requested" || status === "approved",
		requestedStartOn: "2026-09-17",
		requestedDueOn: "2026-09-24",
		approvedStartOn: null,
		approvedDueOn: null,
		checkedOutAt: null,
		returnedAt: null,
		requestNote: null,
		decisionNote: null,
		itemSlug: slug,
		itemLabel: "Regenyei Feder",
		containerPath: null,
		createdAt: "2026-09-17T10:00:00Z",
	};
}

// The four families a member Loan transition stales, plus one it must not.
const catalogListKey = inventoryCatalogListItemsQueryKey({
	query: { limit: 25, availability: "all" },
});
const catalogItemKey = inventoryCatalogShowItemQueryKey({
	path: { slugOrId: slug },
});
const otherItemKey = inventoryCatalogShowItemQueryKey({
	path: { slugOrId: "item-000099" },
});
const myLoansKey = inventoryMemberLoansListQueryKey({
	query: { limit: 25, status: "all" },
});
const loanKey = inventoryMemberLoansShowQueryKey({ path: { loanId } });
const otherLoanKey = inventoryMemberLoansShowQueryKey({
	path: { loanId: "dddddddd-dddd-dddd-dddd-dddddddddddd" },
});
const operatorQueueKey = inventoryOperatorLoanQueueShowQueryKey();

function seededClient(): QueryClient {
	const queryClient = new QueryClient({
		defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
	});
	for (const key of [
		catalogListKey,
		catalogItemKey,
		otherItemKey,
		myLoansKey,
		loanKey,
		otherLoanKey,
		operatorQueueKey,
	]) {
		queryClient.setQueryData(key, { data: {} });
	}
	return queryClient;
}

function invalidated(queryClient: QueryClient) {
	return queryClient
		.getQueryCache()
		.getAll()
		.filter((query) => query.state.isInvalidated)
		.map((query) => query.queryKey);
}

const problem = (errors: { detail?: string; code?: string }) => ({ errors });

beforeEach(() => {
	notify.success.mockClear();
	notify.error.mockClear();
});

describe("member Loan freshness rule", () => {
	it("a request stales the catalog list, that item, my loans, and the new loan", async () => {
		const queryClient = seededClient();
		const requestLoan = vi.fn<RequestLoanFn>(async () => ({
			data: loan("requested"),
		}));
		const observer = new MutationObserver(
			queryClient,
			requestLoanOptions(queryClient, slug, { requestLoan, notify }),
		);

		await observer.mutate({
			path: { slugOrId: slug },
			body: { startsOn: "2026-09-17", dueOn: "2026-09-24" },
		});

		expect(requestLoan.mock.calls[0]?.[0]).toEqual({
			path: { slugOrId: slug },
			body: { startsOn: "2026-09-17", dueOn: "2026-09-24" },
		});
		expect(invalidated(queryClient)).toEqual([
			catalogListKey,
			catalogItemKey,
			myLoansKey,
			loanKey,
		]);
		expect(notify.success).toHaveBeenCalledOnce();
	});

	it("a cancel stales the same four families, including the catalog list", async () => {
		const queryClient = seededClient();
		const cancelLoan = vi.fn<CancelLoanFn>(async () => ({
			data: loan("cancelled"),
		}));
		const observer = new MutationObserver(
			queryClient,
			cancelLoanOptions(queryClient, loanId, { cancelLoan, notify }),
		);

		await observer.mutate({
			path: { loanId },
			body: { note: "Plans changed" },
		});

		expect(cancelLoan.mock.calls[0]?.[0]).toEqual({
			path: { loanId },
			body: { note: "Plans changed" },
		});
		expect(invalidated(queryClient)).toEqual([
			catalogListKey,
			catalogItemKey,
			myLoansKey,
			loanKey,
		]);
		expect(notify.success).toHaveBeenCalledOnce();
	});

	it("a failed transition stales nothing and toasts the member message", async () => {
		const queryClient = seededClient();
		const observer = new MutationObserver(
			queryClient,
			cancelLoanOptions(queryClient, loanId, {
				cancelLoan: async () => {
					throw problem({ detail: "nope", code: "not_cancellable" });
				},
				notify,
			}),
		);

		await expect(observer.mutate({ path: { loanId } })).rejects.toBeDefined();

		expect(invalidated(queryClient)).toEqual([]);
		expect(notify.error).toHaveBeenCalledWith(
			"This loan can no longer be cancelled.",
		);
	});
});

describe("memberLoanErrorMessage", () => {
	it("maps each member Loan code to its member-facing sentence", () => {
		expect(
			memberLoanErrorMessage(
				problem({ detail: "x", code: "duplicate_request" }),
				"fallback",
			),
		).toBe("You already have a pending request for this item.");
		expect(
			memberLoanErrorMessage(
				problem({ detail: "x", code: "item_unavailable" }),
				"fallback",
			),
		).toBe("This item can't be requested right now.");
		expect(
			memberLoanErrorMessage(
				problem({ detail: "x", code: "not_cancellable" }),
				"fallback",
			),
		).toBe("This loan can no longer be cancelled.");
	});

	it("falls back to the detail, then the generic message", () => {
		expect(
			memberLoanErrorMessage(
				problem({ detail: "Starts on must be today or later" }),
				"fallback",
			),
		).toBe("Starts on must be today or later");
		expect(
			memberLoanErrorMessage(
				problem({ detail: "Some new conflict", code: "unknown_code" }),
				"fallback",
			),
		).toBe("Some new conflict");
		expect(memberLoanErrorMessage(new TypeError("offline"), "fallback")).toBe(
			"fallback",
		);
	});

	it("reads the ky-wrapped problem body too", () => {
		expect(
			memberLoanErrorMessage(
				{ data: problem({ code: "duplicate_request" }) },
				"fallback",
			),
		).toBe("You already have a pending request for this item.");
	});
});

describe("labels", () => {
	it("names every availability reason", () => {
		expect(availabilityLabel("available")).toBe("Available");
		expect(availabilityLabel("on_loan")).toBe("On loan");
		expect(availabilityLabel("maintenance")).toBe("Maintenance");
	});

	it("names every loan status", () => {
		expect(loanStatusLabel("requested")).toBe("Requested");
		expect(loanStatusLabel("approved")).toBe("Approved");
		expect(loanStatusLabel("rejected")).toBe("Rejected");
		expect(loanStatusLabel("cancelled")).toBe("Cancelled");
		expect(loanStatusLabel("checked_out")).toBe("Checked out");
		expect(loanStatusLabel("returned")).toBe("Returned");
	});
});

describe("defaultLoanDates", () => {
	it("starts today and runs a week in Club Calendar (Europe/Dublin) days", () => {
		// 23:30 UTC on 2026-10-06 is already 00:30 on 2026-10-07 in Dublin (IST).
		const dates = defaultLoanDates(Date.UTC(2026, 9, 6, 23, 30));
		expect(dates.today.toString()).toBe("2026-10-07");
		expect(dates.startsOn).toBe("2026-10-07");
		expect(dates.dueOn).toBe("2026-10-14");
	});
});
