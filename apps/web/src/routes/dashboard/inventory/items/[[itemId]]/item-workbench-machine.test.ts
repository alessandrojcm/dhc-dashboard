import type { InventoryOperatorItem } from "@dhc/api-client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createActor, fromPromise } from "xstate";
import { type ItemDrafts, itemDrafts, rebasedDrafts } from "./item-drafts";
import {
	type ItemCommand,
	type ItemCommandResult,
	type ItemWorkbenchImplementations,
	itemWorkbenchMachine,
	itemWorkbenchView,
	type WorkbenchRoute,
} from "./item-workbench-machine";

const LIST = "/dashboard/inventory/items";
const FLASH = 650;

const BLADES = "33333333-3333-4333-8333-333333333333";
const MASKS = "44444444-4444-4444-8444-444444444444";
const RACK = "55555555-5555-4555-8555-555555555555";
const CUPBOARD = "66666666-6666-4666-8666-666666666666";
const SIZE = "11111111-1111-4111-8111-111111111111";

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
const mask = item({ id: "item-uuid-2", slug: "item-000002", values: [] });

function route(overrides: Partial<WorkbenchRoute> = {}): WorkbenchRoute {
	return { routeId: undefined, slug: undefined, search: "", ...overrides };
}

type Deferred<T> = {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (cause: unknown) => void;
};

function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	let reject!: (cause: unknown) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

function harness(
	start: Partial<WorkbenchRoute> = {},
	options: {
		lookUpItem?: ItemWorkbenchImplementations["lookUpItem"];
		/** Drafts the injected `rebase` works on, as the controller's would be. */
		drafts?: ItemDrafts;
	} = {},
) {
	const effects = {
		adopt: vi.fn<ItemWorkbenchImplementations["adopt"]>(),
		forget: vi.fn<ItemWorkbenchImplementations["forget"]>(),
		invalidateLists: vi.fn<ItemWorkbenchImplementations["invalidateLists"]>(),
		rebase: vi.fn<ItemWorkbenchImplementations["rebase"]>(),
		resetCreate: vi.fn<ItemWorkbenchImplementations["resetCreate"]>(),
		visit: vi.fn<ItemWorkbenchImplementations["visit"]>(),
		notifySuccess: vi.fn<ItemWorkbenchImplementations["notifySuccess"]>(),
		notifyError: vi.fn<ItemWorkbenchImplementations["notifyError"]>(),
	};
	const lookUpItem = vi.fn<ItemWorkbenchImplementations["lookUpItem"]>(
		options.lookUpItem ?? (async () => mask),
	);
	let drafts = options.drafts;
	effects.rebase.mockImplementation(({ item, own }) => {
		drafts = rebasedDrafts(drafts, item, own);
	});
	const actor = createActor(
		itemWorkbenchMachine.provide({
			actors: {
				lookUpItem: fromPromise(({ input }) => lookUpItem(input)),
			},
			actions: {
				adopt: (_, input) => effects.adopt(input),
				forget: (_, input) => effects.forget(input),
				invalidateLists: (_, input) => effects.invalidateLists(input),
				rebase: (_, input) => effects.rebase(input),
				resetCreate: () => effects.resetCreate(),
				visit: (_, input) => effects.visit(input),
				notifySuccess: (_, input) => effects.notifySuccess(input),
				notifyError: (_, input) => effects.notifyError(input),
			},
		}),
		{ input: { ...route(start), successFlashMs: FLASH } },
	).start();

	/** A command submitted now, to be answered with `settle`. */
	function submit(command: ItemCommand) {
		const { generation, route } = actor.getSnapshot().context;
		return (result: ItemCommandResult) =>
			actor.send({
				type: "SETTLED",
				command,
				generation,
				routeId: route.routeId,
				result,
			});
	}

	return {
		actor,
		effects,
		lookUpItem,
		get drafts() {
			return drafts;
		},
		view: () => itemWorkbenchView(actor.getSnapshot()),
		go: (next: Partial<WorkbenchRoute>) =>
			actor.send({ type: "ROUTED", ...route(next) }),
		submit,
		command: (command: ItemCommand, result: ItemCommandResult) =>
			submit(command)(result),
	};
}

const ok = (data: InventoryOperatorItem): ItemCommandResult => ({
	ok: true,
	data,
});
const refused = (error: string): ItemCommandResult => ({ ok: false, error });

beforeEach(() => {
	vi.useFakeTimers();
});
afterEach(() => {
	vi.useRealTimers();
});

describe("itemWorkbenchMachine", () => {
	describe("routed modes", () => {
		it.each([
			[{}, "list", undefined],
			[{ routeId: "new" }, "create", undefined],
			[{ routeId: "item-000001" }, "manage", "item-000001"],
			[{ routeId: "item-uuid-1" }, "manage", "item-uuid-1"],
		] as const)("routes %o to %s", (start, mode, managedId) => {
			const h = harness(start);
			expect(h.view()).toMatchObject({ mode, managedId });
		});

		it("follows route changes, and ignores a repeated route", () => {
			const h = harness();
			const { generation } = h.actor.getSnapshot().context;

			h.go({ routeId: "new" });
			expect(h.view().mode).toBe("create");
			h.go({ routeId: "item-000001" });
			h.go({ routeId: "item-000001" });
			expect(h.view()).toMatchObject({
				mode: "manage",
				managedId: "item-000001",
			});
			expect(h.actor.getSnapshot().context.generation).toBe(generation + 2);

			h.go({ routeId: "item-000001", search: "?q=blade" });
			expect(h.actor.getSnapshot().context.generation).toBe(generation + 2);
			expect(h.actor.getSnapshot().context.route.search).toBe("?q=blade");
		});

		it("resolves a `?slug=` deep link to the item's route", async () => {
			const h = harness({ slug: "item-uuid-2", search: "?q=x" });
			expect(h.view().resolvingDeepLink).toBe(true);

			await vi.waitFor(() =>
				expect(h.effects.visit).toHaveBeenCalledWith({
					href: `${LIST}/item-000002`,
				}),
			);
			expect(h.lookUpItem).toHaveBeenCalledWith({ slug: "item-uuid-2" });
			expect(h.view().resolvingDeepLink).toBe(false);
		});

		it("says so when a deep link matches no item", async () => {
			const h = harness(
				{ slug: "item-999999" },
				{
					lookUpItem: async () => {
						throw { errors: { detail: "Item not found" } };
					},
				},
			);

			await vi.waitFor(() =>
				expect(h.effects.notifyError).toHaveBeenCalledWith({
					message: "Item not found",
				}),
			);
			expect(h.effects.visit).not.toHaveBeenCalled();
		});

		it("looks a deep link up once, so going back to it does not bounce forward", async () => {
			const h = harness({ slug: "item-000002" });
			await vi.waitFor(() => expect(h.effects.visit).toHaveBeenCalledTimes(1));

			h.go({ routeId: "item-000002" });
			h.go({ slug: "item-000002" });
			h.go({ slug: "item-000002", search: "?q=x" });

			expect(h.view().mode).toBe("list");
			expect(h.lookUpItem).toHaveBeenCalledTimes(1);
			expect(h.effects.visit).toHaveBeenCalledTimes(1);
		});

		it("never navigates for a deep link the operator left before it resolved", async () => {
			const lookup = deferred<InventoryOperatorItem>();
			const h = harness(
				{ slug: "item-000002" },
				{ lookUpItem: () => lookup.promise },
			);

			h.go({ routeId: "new" });
			lookup.resolve(mask);
			await vi.runAllTimersAsync();

			expect(h.effects.visit).not.toHaveBeenCalled();
			expect(h.view().mode).toBe("create");
		});
	});

	describe("management commands", () => {
		const managing = (options?: Parameters<typeof harness>[1]) =>
			harness({ routeId: "item-000001", search: "?q=blade" }, options);

		it.each([
			["update", "details"],
			["move", "placement"],
			["changeCategory", "category"],
			["startMaintenance", "maintenance"],
			["endMaintenance", "maintenance"],
		] as const)(
			"adopts what %s answers, rebases its own drafts and flashes %s",
			(command, form) => {
				const h = managing();
				const answered = item({ notes: "Sharpened" });

				h.command(command, ok(answered));

				expect(h.view().flashing).toBe(form);
				expect(h.effects.adopt).toHaveBeenCalledWith({
					routeId: "item-000001",
					item: answered,
				});
				expect(h.effects.rebase).toHaveBeenCalledWith({
					item: answered,
					own: form,
				});
				expect(h.effects.invalidateLists).toHaveBeenCalledWith({
					slug: "item-000001",
				});
				expect(h.effects.notifySuccess).not.toHaveBeenCalled();
			},
		);

		it("keeps the flash for its full time, then clears it", () => {
			const h = managing();
			h.command("update", ok(item()));

			vi.advanceTimersByTime(FLASH - 1);
			expect(h.view().flashing).toBe("details");
			vi.advanceTimersByTime(1);
			expect(h.view().flashing).toBeNull();
		});

		it("restarts the flash for a repeated success, on the latest form", () => {
			const h = managing();
			h.command("update", ok(item()));
			vi.advanceTimersByTime(FLASH - 100);

			h.command("move", ok(item()));
			expect(h.view().flashing).toBe("placement");
			vi.advanceTimersByTime(FLASH - 1);
			expect(h.view().flashing).toBe("placement");
			vi.advanceTimersByTime(1);
			expect(h.view().flashing).toBeNull();
		});

		it("leaves a refused edit to its form: no adoption, toast or flash", () => {
			const h = managing();

			h.command("move", refused("A loan holds this item"));

			expect(h.view().flashing).toBeNull();
			expect(h.effects.adopt).not.toHaveBeenCalled();
			expect(h.effects.rebase).not.toHaveBeenCalled();
			expect(h.effects.notifyError).not.toHaveBeenCalled();
		});

		it.each([
			["archive", "Item archived"],
			["restore", "Item restored"],
		] as const)(
			"toasts %s and rebases the archive note",
			(command, message) => {
				const h = managing();
				const answered = item({ archivedAt: "2026-10-12T10:00:00Z" });

				h.command(command, ok(answered));

				expect(h.effects.notifySuccess).toHaveBeenCalledWith({ message });
				expect(h.effects.adopt).toHaveBeenCalledWith({
					routeId: "item-000001",
					item: answered,
				});
				expect(h.effects.rebase).toHaveBeenCalledWith({
					item: answered,
					own: "archive",
				});
				expect(h.view().flashing).toBeNull();
			},
		);

		it.each(["archive", "restore", "delete"] as const)(
			"toasts why %s was refused",
			(command) => {
				const h = managing();
				h.actor.send({ type: "CONFIRM_DELETE", open: true });

				h.command(command, refused("Not now"));

				expect(h.effects.notifyError).toHaveBeenCalledWith({
					message: "Not now",
				});
				expect(h.effects.adopt).not.toHaveBeenCalled();
				expect(h.effects.visit).not.toHaveBeenCalled();
				expect(h.view().deleteConfirmOpen).toBe(true);
			},
		);

		it("forgets a deleted item and returns to the list with its search", () => {
			const h = managing();
			h.actor.send({ type: "CONFIRM_DELETE", open: true });

			h.command("delete", ok(item()));

			expect(h.view().deleteConfirmOpen).toBe(false);
			expect(h.effects.forget).toHaveBeenCalledWith({ routeId: "item-000001" });
			expect(h.effects.visit).toHaveBeenCalledWith({ href: `${LIST}?q=blade` });
			expect(h.effects.invalidateLists).toHaveBeenCalledWith({});
			expect(h.effects.notifySuccess).not.toHaveBeenCalled();
		});

		it("ignores a repeated or late answer for an item it just deleted", () => {
			const h = managing();
			const late = h.submit("update");
			h.command("delete", ok(item()));

			h.command("delete", ok(item()));
			late(ok(item({ notes: "Sharpened" })));

			expect(h.effects.visit).toHaveBeenCalledTimes(1);
			expect(h.effects.forget).toHaveBeenCalledTimes(1);
			expect(h.effects.adopt).not.toHaveBeenCalled();
		});

		it("closes the delete confirmation when another item is routed", () => {
			const h = managing();
			h.actor.send({ type: "CONFIRM_DELETE", open: true });

			h.go({ routeId: "item-000002" });

			expect(h.view().deleteConfirmOpen).toBe(false);
		});
	});

	describe("an answer that lands after the route changed", () => {
		it("adopts into its own item's cache but never rebases, flashes or navigates", () => {
			const h = harness({ routeId: "item-000001" });
			const update = h.submit("update");
			const remove = h.submit("delete");

			h.go({ routeId: "item-000002" });
			const answered = item({ notes: "Sharpened" });
			update(ok(answered));
			remove(ok(item()));

			expect(h.effects.adopt).toHaveBeenCalledWith({
				routeId: "item-000001",
				item: answered,
			});
			expect(h.effects.forget).toHaveBeenCalledWith({ routeId: "item-000001" });
			expect(h.effects.rebase).not.toHaveBeenCalled();
			expect(h.effects.visit).not.toHaveBeenCalled();
			expect(h.view()).toMatchObject({
				mode: "manage",
				managedId: "item-000002",
				flashing: null,
			});
		});

		it("still says how an archive went", () => {
			const h = harness({ routeId: "item-000001" });
			const archive = h.submit("archive");
			h.go({});

			archive(ok(item()));

			expect(h.effects.notifySuccess).toHaveBeenCalledWith({
				message: "Item archived",
			});
			expect(h.effects.rebase).not.toHaveBeenCalled();
		});

		it("cancels a running flash when the operator leaves the item", () => {
			const h = harness({ routeId: "item-000001" });
			h.command("update", ok(item()));

			h.go({ routeId: "item-000002" });
			expect(h.view().flashing).toBeNull();
			vi.runAllTimers();
			expect(h.view().flashing).toBeNull();
		});
	});

	describe("create", () => {
		it("adopts the new item, flashes Add, then empties the form and opens it", () => {
			const h = harness({ routeId: "new", search: "?availability=on_loan" });
			const added = item({ slug: "item-000003" });

			h.command("create", ok(added));

			expect(h.view().flashing).toBe("create");
			expect(h.effects.adopt).toHaveBeenCalledWith({
				routeId: "item-000003",
				item: added,
			});
			expect(h.effects.invalidateLists).toHaveBeenCalledWith({
				slug: "item-000003",
			});
			vi.advanceTimersByTime(FLASH - 1);
			expect(h.effects.visit).not.toHaveBeenCalled();
			expect(h.effects.resetCreate).not.toHaveBeenCalled();

			vi.advanceTimersByTime(1);
			expect(h.view().flashing).toBeNull();
			expect(h.effects.resetCreate).toHaveBeenCalledTimes(1);
			expect(h.effects.visit).toHaveBeenCalledWith({
				href: `${LIST}/item-000003?availability=on_loan`,
			});
		});

		it("keeps the form when adding is refused", () => {
			const h = harness({ routeId: "new" });

			h.command("create", refused("Could not create item"));
			vi.runAllTimers();

			expect(h.view().flashing).toBeNull();
			expect(h.effects.resetCreate).not.toHaveBeenCalled();
			expect(h.effects.visit).not.toHaveBeenCalled();
			expect(h.effects.notifyError).not.toHaveBeenCalled();
		});

		it("drops the delayed open when the operator leaves first, but still empties the saved form", () => {
			const h = harness({ routeId: "new" });
			h.command("create", ok(item({ slug: "item-000003" })));

			h.go({});
			vi.runAllTimers();

			expect(h.effects.visit).not.toHaveBeenCalled();
			expect(h.effects.resetCreate).toHaveBeenCalledTimes(1);
			expect(h.view().mode).toBe("list");
		});

		it("adopts a create answered after the operator left, without opening it", () => {
			const h = harness({ routeId: "new" });
			const create = h.submit("create");
			h.go({});

			const added = item({ slug: "item-000003" });
			create(ok(added));
			vi.runAllTimers();

			expect(h.effects.adopt).toHaveBeenCalledWith({
				routeId: "item-000003",
				item: added,
			});
			expect(h.effects.visit).not.toHaveBeenCalled();
			expect(h.effects.resetCreate).not.toHaveBeenCalled();
		});
	});

	describe("teardown", () => {
		it("cancels the flash and the delayed open, and drops late answers", () => {
			const h = harness({ routeId: "new" });
			h.command("create", ok(item({ slug: "item-000003" })));

			h.actor.stop();
			vi.runAllTimers();

			expect(h.effects.visit).not.toHaveBeenCalled();
			expect(h.actor.getSnapshot().status).toBe("stopped");
		});
	});

	describe("rebased drafts", () => {
		function managingWithDrafts() {
			const drafts = itemDrafts(longsword);
			const h = harness({ routeId: "item-000001" }, { drafts });
			return { h, fields: drafts.fields };
		}

		it("starts the submitting form again and keeps another form's unsaved edit", () => {
			const { h, fields } = managingWithDrafts();
			fields.notes = "Sharpened";
			fields.containerId = CUPBOARD;
			fields.maintenanceReason = "Inspect strap";
			fields.archiveReason = "Retired";

			h.command("move", ok(item({ containerId: CUPBOARD })));

			expect(h.drafts?.fields).toMatchObject({
				notes: "Sharpened",
				containerId: CUPBOARD,
				maintenanceReason: "Inspect strap",
				archiveReason: "Retired",
			});

			h.command("startMaintenance", ok(item({ containerId: CUPBOARD })));
			expect(h.drafts?.fields).toMatchObject({
				notes: "Sharpened",
				maintenanceReason: "",
				archiveReason: "Retired",
			});
		});

		it("rebases another form's unsaved edit when the answer changed what it edits", () => {
			const { h, fields } = managingWithDrafts();
			fields.notes = "Sharpened";

			h.command("changeCategory", ok(item({ categoryId: MASKS, values: [] })));

			expect(h.drafts?.fields).toMatchObject({
				notes: "Training loaner",
				values: {},
				categoryId: MASKS,
			});
		});

		it("leaves the drafts alone for a refusal or a stale answer", () => {
			const { h, fields } = managingWithDrafts();
			fields.notes = "Sharpened";
			const stale = h.submit("update");

			h.command("update", refused("Item is archived"));
			h.go({ routeId: "item-000002" });
			stale(ok(item({ notes: "Other" })));

			expect(h.drafts?.fields.notes).toBe("Sharpened");
		});
	});
});
