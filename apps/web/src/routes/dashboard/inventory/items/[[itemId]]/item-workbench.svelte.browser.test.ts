import { QueryClient } from "@tanstack/svelte-query";
import {
	type InventoryItemsListData,
	type InventoryOperatorItem,
	type Options,
	inventoryItemsListQueryKey,
} from "@dhc/api-client";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
	createItemWorkbench,
	type FlashedForm,
	type ItemCommandResult,
	type ItemWorkbench,
	type ItemWorkbenchDeps,
} from "./item-workbench.svelte.js";

const ORIGIN = "https://dhc.test";
const LIST = "/dashboard/inventory/items";

const SIZE = "11111111-1111-4111-8111-111111111111";
const PADDED = "22222222-2222-4222-8222-222222222222";
const BLADES = "33333333-3333-4333-8333-333333333333";
const MASKS = "44444444-4444-4444-8444-444444444444";
const RACK = "55555555-5555-4555-8555-555555555555";
const CUPBOARD = "66666666-6666-4666-8666-666666666666";

function item(
	overrides: Partial<InventoryOperatorItem> = {},
): InventoryOperatorItem {
	return {
		id: "item-uuid-1",
		slug: "item-000001",
		label: "Blades Medium",
		categoryId: BLADES,
		containerId: RACK,
		category: { id: BLADES, name: "Blades", archivedAt: null },
		container: { id: RACK, name: "Rack", archivedAt: null },
		values: [
			{
				definitionId: SIZE,
				definitionLabel: "Size",
				valueType: "single_select",
				identifyingPosition: 0,
				text: null,
				decimal: null,
				boolean: null,
				optionId: "opt-medium",
				optionLabel: "Medium",
			},
		],
		notes: "Training loaner",
		availability: { available: true, status: "available" },
		archivedAt: null,
		...overrides,
	};
}

const longsword = item();
const mask = item({
	id: "item-uuid-2",
	slug: "item-000002",
	label: "Masks Black",
	categoryId: MASKS,
	values: [],
	notes: null,
});

function listPage(
	items: InventoryOperatorItem[],
	cursors: { next?: string; previous?: string } = {},
) {
	return {
		data: {
			items,
			totalCount: items.length,
			limit: 25 as const,
			nextCursor: cursors.next ?? null,
			previousCursor: cursors.previous ?? null,
		},
	};
}

function submission(result: ItemCommandResult, valid = true) {
	return { submit: async () => valid, result };
}

type Navigation = { href: string; replace: boolean };

const cleanups: (() => void)[] = [];
afterEach(() => {
	for (const cleanup of cleanups.splice(0)) cleanup();
});

function harness(
	options: {
		path?: string;
		requests?: ItemWorkbenchDeps["requests"];
		items?: InventoryOperatorItem[];
		/** Long by default, so a test can see a button's success state. */
		successFlashMs?: number;
	} = {},
) {
	const queryClient = new QueryClient({
		defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
	});
	let url = $state(new URL(options.path ?? LIST, ORIGIN));
	const routeId = () => {
		const rest = url.pathname.slice(LIST.length + 1);
		return rest || undefined;
	};
	const navigations: Navigation[] = [];
	const visits: string[] = [];
	const notify = { success: vi.fn(), error: vi.fn() };
	const listCalls: Options<InventoryItemsListData>[] = [];
	const known = options.items ?? [longsword, mask];
	const go = (href: string) => {
		url = new URL(href, ORIGIN);
	};

	let created: ItemWorkbench | undefined;
	const destroy = $effect.root(() => {
		created = createItemWorkbench({
			queryClient,
			url: () => url,
			itemId: routeId,
			navigate: (href, { replace }) => {
				navigations.push({ href, replace });
				go(href);
			},
			visit: (href) => {
				visits.push(href);
				go(href);
			},
			notify,
			successFlashMs: options.successFlashMs ?? 60_000,
			requests: {
				list: async (request) => {
					listCalls.push(request);
					return listPage(known);
				},
				show: async ({ path }) => {
					const found = known.find(
						(candidate) =>
							candidate.slug === path.slugOrId ||
							candidate.id === path.slugOrId,
					);
					if (!found) throw { errors: { detail: "Item not found" } };
					return { data: found };
				},
				categories: async () => ({ data: { categories: [] } }),
				containers: async () => ({ data: { containers: [] } }),
				definitions: async () => ({ data: { definitions: [] } }),
				maintenance: async () => ({ data: { periods: [] } }),
				...options.requests,
			},
		});
	});
	if (!created) throw new Error("createItemWorkbench did not run");
	const workbench = created;
	cleanups.push(() => {
		destroy();
		queryClient.clear();
	});
	return {
		workbench,
		queryClient,
		navigations,
		visits,
		notify,
		listCalls,
		get url() {
			return url;
		},
		go,
		listed: () =>
			vi.waitFor(() => expect(workbench.items.length).toBeGreaterThan(0)),
		selectedLoaded: () =>
			vi.waitFor(() => expect(workbench.drafts).toBeDefined()),
	};
}

describe("createItemWorkbench", () => {
	describe("list", () => {
		it("requests active items, 25 to a page, with no availability filter", async () => {
			const h = harness();
			await h.listed();

			expect(h.listCalls.at(-1)).toEqual({
				query: { limit: 25, direction: "asc", archived: "exclude" },
			});
			expect(h.workbench.items.map((row) => row.slug)).toEqual([
				"item-000001",
				"item-000002",
			]);
			expect(h.workbench.totalCount).toBe(2);
			expect(h.workbench.availability).toBe("all");
			expect(h.workbench.archived).toBe("exclude");
		});

		it("reads search, filters and cursor from the URL", async () => {
			const h = harness({
				path: `${LIST}?q=mask&availability=on_loan&archived=include&cursor=c2`,
			});
			await h.listed();

			expect(h.listCalls.at(-1)).toEqual({
				query: {
					limit: 25,
					direction: "asc",
					archived: "include",
					availability: "on_loan",
					q: "mask",
					cursor: "c2",
				},
			});
			expect(h.workbench.search).toBe("mask");
			expect(h.workbench.searching).toBe(true);
			expect(h.workbench.activeFilterCount).toBe(2);
		});

		it("ignores a filter value it does not offer instead of sending it", async () => {
			const h = harness({ path: `${LIST}?availability=lost&archived=maybe` });
			await h.listed();

			expect(h.workbench.availability).toBe("all");
			expect(h.workbench.archived).toBe("exclude");
			expect(h.listCalls.at(-1)?.query).not.toHaveProperty("availability");
		});

		it("replaces the entry and drops the cursor when a filter changes", async () => {
			const h = harness({ path: `${LIST}?cursor=c2` });

			h.workbench.setAvailability("maintenance");
			expect(h.navigations).toEqual([
				{ href: `${LIST}?availability=maintenance`, replace: true },
			]);
			await vi.waitFor(() =>
				expect(h.listCalls.at(-1)?.query).toMatchObject({
					availability: "maintenance",
				}),
			);
			expect(h.listCalls.at(-1)?.query).not.toHaveProperty("cursor");

			h.workbench.setAvailability("all");
			expect(h.navigations.at(-1)).toEqual({ href: LIST, replace: true });
		});

		it("clears both filters in one replace", () => {
			const h = harness({
				path: `${LIST}?availability=available&archived=only&q=mask`,
			});

			h.workbench.clearFilters();

			expect(h.navigations).toEqual([
				{ href: `${LIST}?q=mask`, replace: true },
			]);
			expect(h.workbench.activeFilterCount).toBe(0);
		});

		it("writes the trimmed search after a debounce, replacing the entry", async () => {
			const h = harness({ path: `${LIST}?cursor=c2` });

			h.workbench.setSearch("  Training loaner  ");
			expect(h.workbench.search).toBe("  Training loaner  ");
			expect(h.navigations).toEqual([]);

			await vi.waitFor(() =>
				expect(h.navigations).toEqual([
					{ href: `${LIST}?q=Training+loaner`, replace: true },
				]),
			);
		});

		it("pushes an entry for each page", async () => {
			const h = harness({
				requests: {
					list: async () =>
						listPage([longsword], { next: "c2", previous: "c0" }),
				},
			});
			await h.listed();
			expect(h.workbench.paged).toBe(true);

			h.workbench.nextPage();
			expect(h.navigations.at(-1)).toEqual({
				href: `${LIST}?cursor=c2`,
				replace: false,
			});
		});

		it("is not paged when there is one page", async () => {
			const h = harness();
			await h.listed();

			expect(h.workbench.paged).toBe(false);
		});

		it("carries the list's search and filters to item routes and back", () => {
			const h = harness({ path: `${LIST}?q=mask&availability=on_loan` });

			expect(h.workbench.itemHref("item-000002")).toBe(
				`${LIST}/item-000002?q=mask&availability=on_loan`,
			);
			expect(h.workbench.newItemHref).toBe(
				`${LIST}/new?q=mask&availability=on_loan`,
			);
			expect(h.workbench.listHref).toBe(`${LIST}?q=mask&availability=on_loan`);
		});
	});

	describe("selection", () => {
		it("loads the routed item and starts its drafts from it", async () => {
			const h = harness({ path: `${LIST}/item-000001` });
			await h.selectedLoaded();

			expect(h.workbench.routed).toBe(true);
			expect(h.workbench.creating).toBe(false);
			expect(h.workbench.selected?.slug).toBe("item-000001");
			expect(h.workbench.drafts).toMatchObject({
				notes: "Training loaner",
				values: { [SIZE]: "opt-medium" },
				containerId: RACK,
				categoryId: BLADES,
			});
			expect(h.workbench.managementTab).toBe("details");
		});

		it("does not list items while an item is routed", async () => {
			const h = harness({ path: `${LIST}/item-000001` });
			await h.selectedLoaded();

			expect(h.listCalls).toEqual([]);
		});

		it("opens the create form on `new`, with nothing selected", () => {
			const h = harness({ path: `${LIST}/new` });

			expect(h.workbench.creating).toBe(true);
			expect(h.workbench.selected).toBeUndefined();
			expect(h.workbench.drafts).toBeUndefined();
		});

		it("starts fresh drafts, on the details tab, when another item is routed", async () => {
			const h = harness({ path: `${LIST}/item-000001` });
			await h.selectedLoaded();
			h.workbench.drafts!.notes = "Edited";
			h.workbench.managementTab = "maintenance";

			h.go(`${LIST}/item-000002`);
			await vi.waitFor(() =>
				expect(h.workbench.selected?.slug).toBe("item-000002"),
			);

			expect(h.workbench.drafts?.notes).toBe("");
			expect(h.workbench.managementTab).toBe("details");
		});

		it("resolves a `?slug=` deep link to the item's route", async () => {
			const h = harness({ path: `${LIST}?slug=item-uuid-2` });

			await vi.waitFor(() => expect(h.visits).toEqual([`${LIST}/item-000002`]));
		});

		it("says so when a `?slug=` deep link matches no item", async () => {
			const h = harness({ path: `${LIST}?slug=item-999999` });

			await vi.waitFor(() =>
				expect(h.notify.error).toHaveBeenCalledWith("Item not found"),
			);
			expect(h.visits).toEqual([]);
		});
	});

	describe("drafts", () => {
		it("is dirty only while the details differ from the item", async () => {
			const h = harness({ path: `${LIST}/item-000001` });
			await h.selectedLoaded();
			const definition = { id: PADDED, valueType: "boolean" } as const;

			expect(h.workbench.dirty.details).toBe(false);
			h.workbench.drafts!.notes = "  Training loaner  ";
			expect(h.workbench.dirty.details).toBe(false);

			h.workbench.setValue("details", definition, "false");
			expect(h.workbench.dirty.details).toBe(true);
			expect(JSON.parse(h.workbench.encoded.details)).toEqual({
				[SIZE]: "opt-medium",
				[PADDED]: false,
			});

			h.workbench.setValue("details", definition, "");
			expect(h.workbench.dirty.details).toBe(false);
		});

		it("is dirty while another container is chosen", async () => {
			const h = harness({ path: `${LIST}/item-000001` });
			await h.selectedLoaded();

			h.workbench.drafts!.containerId = CUPBOARD;
			expect(h.workbench.dirty.placement).toBe(true);
			h.workbench.drafts!.containerId = RACK;
			expect(h.workbench.dirty.placement).toBe(false);
		});

		it("empties the values for another category and restores them for the item's own", async () => {
			const h = harness({ path: `${LIST}/item-000001` });
			await h.selectedLoaded();

			h.workbench.chooseNewCategory(MASKS);
			expect(h.workbench.drafts?.categoryValues).toEqual({});
			expect(h.workbench.dirty.category).toBe(true);

			h.workbench.chooseNewCategory(BLADES);
			expect(h.workbench.drafts?.categoryValues).toEqual({
				[SIZE]: "opt-medium",
			});
			expect(h.workbench.dirty.category).toBe(false);
		});

		it("empties the create form's values when its category changes", () => {
			const h = harness({ path: `${LIST}/new` });
			h.workbench.chooseCreateCategory(BLADES);
			h.workbench.setValue(
				"create",
				{ id: SIZE, valueType: "single_select" },
				"opt-medium",
			);
			expect(JSON.parse(h.workbench.encoded.create)).toEqual({
				[SIZE]: "opt-medium",
			});

			h.workbench.chooseCreateCategory(MASKS);
			expect(h.workbench.create.values).toEqual({});
		});
	});

	describe("commands", () => {
		async function managing() {
			const h = harness({ path: `${LIST}/item-000001?q=blade` });
			await h.selectedLoaded();
			return h;
		}

		it("adopts the item an update answers with and flashes Save", async () => {
			const h = await managing();
			const invalidate = vi.spyOn(h.queryClient, "invalidateQueries");
			h.workbench.drafts!.notes = "Sharpened";
			const answered = item({ notes: "Sharpened" });

			await h.workbench.enhance.update(
				submission({ ok: true, data: answered }),
			);
			expect(h.workbench.succeeded("details")).toBe(true);

			expect(h.workbench.drafts?.notes).toBe("Sharpened");
			expect(h.workbench.dirty.details).toBe(false);
			await vi.waitFor(() =>
				expect(h.workbench.selected?.notes).toBe("Sharpened"),
			);
			expect(invalidate).toHaveBeenCalledWith({
				queryKey: inventoryItemsListQueryKey(),
			});
			expect(h.notify.success).not.toHaveBeenCalled();
		});

		it("keeps the drafts and stays quiet when an update is refused", async () => {
			const h = await managing();
			h.workbench.drafts!.notes = "Sharpened";

			await h.workbench.enhance.update(
				submission({ ok: false, error: "Item is archived" }),
			);

			expect(h.workbench.drafts?.notes).toBe("Sharpened");
			expect(h.workbench.dirty.details).toBe(true);
			expect(h.workbench.succeeded("details")).toBe(false);
			expect(h.notify.error).not.toHaveBeenCalled();
		});

		it("does nothing for a submission that failed validation", async () => {
			const h = await managing();
			h.workbench.drafts!.notes = "Sharpened";

			await h.workbench.enhance.update(
				submission({ ok: true, data: item({ notes: "x" }) }, false),
			);

			expect(h.workbench.drafts?.notes).toBe("Sharpened");
			expect(h.workbench.succeeded("details")).toBe(false);
		});

		it.each<
			[
				"move" | "changeCategory" | "startMaintenance" | "endMaintenance",
				FlashedForm,
				Partial<InventoryOperatorItem>,
			]
		>([
			["move", "placement", { containerId: CUPBOARD }],
			["changeCategory", "category", { categoryId: MASKS, values: [] }],
			[
				"startMaintenance",
				"maintenance",
				{ availability: { available: false, status: "maintenance" } },
			],
			["endMaintenance", "maintenance", {}],
		])(
			"adopts the item %s answers with and flashes its form",
			async (command, form, changes) => {
				const h = await managing();
				const answered = item(changes);

				await h.workbench.enhance[command](
					submission({ ok: true, data: answered }),
				);
				expect(h.workbench.succeeded(form)).toBe(true);

				expect(h.workbench.drafts).toMatchObject({
					containerId: answered.containerId,
					categoryId: answered.categoryId,
				});
				expect(h.workbench.dirty).toEqual({
					details: false,
					placement: false,
					category: false,
				});
			},
		);

		it.each([
			["move", "placement"],
			["changeCategory", "category"],
			["startMaintenance", "maintenance"],
			["endMaintenance", "maintenance"],
		] as const)(
			"leaves the drafts and stays quiet when %s is refused",
			async (command, form) => {
				const h = await managing();
				h.workbench.drafts!.containerId = CUPBOARD;
				h.workbench.drafts!.maintenanceReason = "Inspect strap";

				await h.workbench.enhance[command](
					submission({ ok: false, error: "A loan holds this item" }),
				);

				expect(h.workbench.drafts).toMatchObject({
					containerId: CUPBOARD,
					maintenanceReason: "Inspect strap",
				});
				expect(h.workbench.succeeded(form)).toBe(false);
				expect(h.notify.error).not.toHaveBeenCalled();
			},
		);

		// The E2E race: a note typed in another tab while a command was still
		// running survived only until that command's success replaced every
		// draft, which left "Start maintenance" disabled.
		it("keeps a note typed while another command ran, and clears it once its own command succeeds", async () => {
			const h = await managing();
			h.workbench.drafts!.containerId = CUPBOARD;
			h.workbench.drafts!.maintenanceReason = "Inspect strap";
			h.workbench.drafts!.archiveReason = "Retired";

			await h.workbench.enhance.move(
				submission({ ok: true, data: item({ containerId: CUPBOARD }) }),
			);
			expect(h.workbench.drafts).toMatchObject({
				containerId: CUPBOARD,
				maintenanceReason: "Inspect strap",
				archiveReason: "Retired",
			});
			expect(h.workbench.dirty.placement).toBe(false);

			await h.workbench.enhance.startMaintenance(
				submission({
					ok: true,
					data: item({
						containerId: CUPBOARD,
						availability: { available: false, status: "maintenance" },
					}),
				}),
			);
			expect(h.workbench.drafts).toMatchObject({
				maintenanceReason: "",
				archiveReason: "Retired",
			});
		});

		it("keeps another form's unsaved edit unless the answer changed what it edits", async () => {
			const h = await managing();
			h.workbench.drafts!.notes = "Sharpened";

			await h.workbench.enhance.move(
				submission({ ok: true, data: item({ containerId: CUPBOARD }) }),
			);
			expect(h.workbench.drafts?.notes).toBe("Sharpened");
			expect(h.workbench.dirty.details).toBe(true);

			// A new category replaces the properties the details form edits, so
			// its draft follows the answer.
			await h.workbench.enhance.changeCategory(
				submission({
					ok: true,
					data: item({ containerId: CUPBOARD, categoryId: MASKS, values: [] }),
				}),
			);
			expect(h.workbench.drafts).toMatchObject({
				notes: "Training loaner",
				values: {},
				categoryId: MASKS,
			});
			expect(h.workbench.dirty).toEqual({
				details: false,
				placement: false,
				category: false,
			});
		});

		it("adds an item, then opens it once the button has flashed", async () => {
			const h = harness({
				path: `${LIST}/new?availability=on_loan`,
				successFlashMs: 0,
			});
			h.workbench.chooseCreateCategory(BLADES);
			h.workbench.create.containerId = RACK;
			h.workbench.create.notes = "Spare";
			const added = item({ slug: "item-000003" });

			await h.workbench.enhance.create(submission({ ok: true, data: added }));
			expect(h.workbench.succeeded("create")).toBe(true);

			await vi.waitFor(() =>
				expect(h.visits).toEqual([`${LIST}/item-000003?availability=on_loan`]),
			);
			expect(h.workbench.create).toEqual({
				categoryId: "",
				containerId: "",
				notes: "",
				values: {},
			});
			// The new route shows the answered item without another read.
			await vi.waitFor(() =>
				expect(h.workbench.selected?.slug).toBe("item-000003"),
			);
		});

		it("keeps the create form as it was when adding is refused", async () => {
			const h = harness({ path: `${LIST}/new` });
			h.workbench.chooseCreateCategory(BLADES);

			await h.workbench.enhance.create(
				submission({ ok: false, error: "Could not create item" }),
			);

			expect(h.workbench.create.categoryId).toBe(BLADES);
			expect(h.workbench.succeeded("create")).toBe(false);
			expect(h.visits).toEqual([]);
		});

		it("toasts an archive and adopts the archived item", async () => {
			const h = await managing();
			const archived = item({
				archivedAt: "2026-10-12T10:00:00Z",
				availability: { available: false, status: "archived" },
			});

			await h.workbench.enhance.archive(
				submission({ ok: true, data: archived }),
			);

			expect(h.notify.success).toHaveBeenCalledWith("Item archived");
			await vi.waitFor(() =>
				expect(h.workbench.selected?.archivedAt).toBe("2026-10-12T10:00:00Z"),
			);
		});

		it("toasts why an archive was refused", async () => {
			const h = await managing();

			await h.workbench.enhance.archive(
				submission({ ok: false, error: "A loan holds this item" }),
			);

			expect(h.notify.error).toHaveBeenCalledWith("A loan holds this item");
			expect(h.notify.success).not.toHaveBeenCalled();
		});

		it("toasts a restore, and why one was refused", async () => {
			const h = await managing();

			await h.workbench.enhance.restore(submission({ ok: true, data: item() }));
			expect(h.notify.success).toHaveBeenCalledWith("Item restored");

			await h.workbench.enhance.restore(
				submission({ ok: false, error: "Could not restore item" }),
			);
			expect(h.notify.error).toHaveBeenCalledWith("Could not restore item");
		});

		it("returns to the list, with its filters, after a delete", async () => {
			const h = await managing();
			h.workbench.deleteConfirmOpen = true;

			await h.workbench.enhance.delete(submission({ ok: true, data: item() }));

			expect(h.visits).toEqual([`${LIST}?q=blade`]);
			expect(h.workbench.deleteConfirmOpen).toBe(false);
			expect(h.notify.success).not.toHaveBeenCalled();
		});

		it("keeps the confirmation open and says why a delete was refused", async () => {
			const h = await managing();
			h.workbench.deleteConfirmOpen = true;

			await h.workbench.enhance.delete(
				submission({ ok: false, error: "Items with history must be archived" }),
			);

			expect(h.notify.error).toHaveBeenCalledWith(
				"Items with history must be archived",
			);
			expect(h.workbench.deleteConfirmOpen).toBe(true);
			expect(h.visits).toEqual([]);
		});
	});
});
