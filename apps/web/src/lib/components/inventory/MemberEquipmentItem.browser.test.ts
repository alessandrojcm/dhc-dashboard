import {
	inventoryCatalogListItemsQueryKey,
	inventoryCatalogShowItemQueryKey,
	inventoryMemberLoansListQueryKey,
	type InventoryCatalogItem,
	type InventoryMemberLoan,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import MemberEquipmentItemTestWrapper from "./MemberEquipmentItem.test-wrapper.svelte";

const slug = "item-000042";

const item: InventoryCatalogItem = {
	id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
	slug,
	label: "Regenyei Feder",
	category: { id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", name: "Longsword" },
	values: [],
	availability: { available: true, reason: "available" },
};

const createdLoan: InventoryMemberLoan = {
	id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
	itemId: item.id,
	status: "requested",
	overdue: false,
	requestedStartOn: "2026-09-17",
	requestedDueOn: "2026-09-24",
	approvedStartOn: null,
	approvedDueOn: null,
	checkedOutAt: null,
	returnedAt: null,
	requestNote: null,
	decisionNote: null,
	itemSlug: slug,
	itemLabel: item.label,
	containerPath: null,
	createdAt: "2026-09-17T10:00:00Z",
};

test("invalidates the catalog show query after a request", async () => {
	const showKey = inventoryCatalogShowItemQueryKey({
		path: { slugOrId: slug },
	});
	const queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false, staleTime: Infinity, refetchOnMount: false },
			mutations: { retry: false },
		},
	});
	queryClient.setQueryData(showKey, { data: item });
	const invalidate = vi.spyOn(queryClient, "invalidateQueries");
	const requestLoan = vi.fn(async () => ({ data: createdLoan }));

	const screen = await render(MemberEquipmentItemTestWrapper, {
		slug,
		queryClient,
		requestLoan,
	});

	await expect
		.element(screen.getByRole("heading", { name: "Regenyei Feder" }))
		.toBeVisible();

	await screen.getByRole("button", { name: "Send request" }).click();

	await expect.poll(() => invalidate.mock.calls.length).toBeGreaterThan(0);
	expect(requestLoan).toHaveBeenCalledOnce();
	expect(invalidate).toHaveBeenCalledWith({ queryKey: showKey });
	expect(invalidate).toHaveBeenCalledWith({
		queryKey: inventoryMemberLoansListQueryKey(),
	});
	expect(invalidate).toHaveBeenCalledWith({
		queryKey: inventoryCatalogListItemsQueryKey(),
	});
});
