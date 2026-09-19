import {
	configureClient,
	getClient,
	inventoryCatalogShowItemQueryKey,
	inventoryMemberLoansListQueryKey,
	inventoryMemberLoansShowQueryKey,
	type InventoryMemberLoan,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import MemberLoanDetailTestWrapper from "./MemberLoanDetail.test-wrapper.svelte";

const loanId = "cccccccc-cccc-cccc-cccc-cccccccccccc";
const itemSlug = "item-000042";

function loan(status: InventoryMemberLoan["status"]): InventoryMemberLoan {
	return {
		id: loanId,
		itemId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
		status,
		overdue: false,
		requestedStartOn: "2026-09-17",
		requestedDueOn: "2026-09-24",
		approvedStartOn: null,
		approvedDueOn: null,
		checkedOutAt: null,
		returnedAt: null,
		requestNote: null,
		decisionNote: null,
		itemSlug,
		itemLabel: "Regenyei Feder",
		containerPath: null,
		createdAt: "2026-09-17T10:00:00Z",
	};
}

function requestUrl(input: RequestInfo | URL): string {
	if (input instanceof Request) return input.url;
	if (input instanceof URL) return input.href;
	return input;
}

function requestMethod(input: RequestInfo | URL, init?: RequestInit): string {
	if (init?.method) return init.method.toUpperCase();
	if (input instanceof Request) return input.method.toUpperCase();
	return "GET";
}

type JsonBody = { data: InventoryMemberLoan } | { errors: { detail: string } };

function jsonResponse(body: JsonBody, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json" },
	});
}

test("invalidates the loan show query after cancel", async () => {
	configureClient({ baseUrl: "/api", credentials: "include", retry: 0 });
	let current = loan("requested");
	getClient().setConfig({
		kyOptions: {
			fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
				const url = requestUrl(input);
				const method = requestMethod(input, init);
				if (
					method === "GET" &&
					url.includes(`/inventory/loans/mine/${loanId}`)
				) {
					return jsonResponse({ data: current });
				}
				if (
					method === "POST" &&
					url.includes(`/inventory/loans/mine/${loanId}/cancel`)
				) {
					current = loan("cancelled");
					return jsonResponse({ data: current });
				}
				return jsonResponse({ errors: { detail: url } }, 404);
			},
		},
	});

	const showKey = inventoryMemberLoansShowQueryKey({ path: { loanId } });
	const queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false, staleTime: Infinity, refetchOnMount: false },
			mutations: { retry: false },
		},
	});
	queryClient.setQueryData(showKey, { data: current });
	const invalidate = vi.spyOn(queryClient, "invalidateQueries");

	const screen = await render(MemberLoanDetailTestWrapper, {
		loanId,
		queryClient,
	});

	await expect
		.element(screen.getByRole("heading", { name: "Regenyei Feder" }))
		.toBeVisible();

	await screen.getByRole("button", { name: "Cancel loan" }).click();

	await expect.poll(() => invalidate.mock.calls.length).toBeGreaterThan(0);
	expect(invalidate).toHaveBeenCalledWith({ queryKey: showKey });
	expect(invalidate).toHaveBeenCalledWith({
		queryKey: inventoryMemberLoansListQueryKey(),
	});
	expect(invalidate).toHaveBeenCalledWith({
		queryKey: inventoryCatalogShowItemQueryKey({
			path: { slugOrId: itemSlug },
		}),
	});
});
