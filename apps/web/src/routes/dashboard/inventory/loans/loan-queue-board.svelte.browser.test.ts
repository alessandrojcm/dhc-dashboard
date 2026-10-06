import { QueryClient } from "@tanstack/svelte-query";
import {
	type InventoryOperatorLoan,
	type InventoryOperatorLoanHandover,
	type InventoryOperatorLoanQueue,
	inventoryItemsListQueryKey,
	inventoryItemsShowQueryKey,
	inventoryOperatorLoanQueueShowQueryKey,
} from "@dhc/api-client";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
	createLoanQueueBoard,
	type LoanQueueBoard,
	type LoanQueueBoardDeps,
	type LoanQueueHover,
} from "./loan-queue-board.svelte.js";

const BASE = "https://dhc.test/dashboard/inventory/loans";

function loan(
	overrides: Partial<InventoryOperatorLoan> = {},
): InventoryOperatorLoan {
	return {
		id: "loan-1",
		itemId: "item-uuid-1",
		borrowerPrincipalId: "principal-1",
		status: "requested",
		overdue: false,
		requestedStartOn: "2026-10-10",
		requestedDueOn: "2026-10-17",
		approvedStartOn: null,
		approvedDueOn: null,
		checkedOutAt: null,
		returnedAt: null,
		decidedAt: null,
		decidedByPrincipalId: null,
		returnedByPrincipalId: null,
		requestNote: null,
		decisionNote: null,
		itemSlug: "item-000001",
		itemLabel: "Longsword",
		containerPath: null,
		createdAt: "2026-10-01T10:00:00Z",
		...overrides,
	};
}

const requested = loan({ id: "req-1", status: "requested" });
const approved: InventoryOperatorLoanHandover = {
	...loan({
		id: "app-1",
		itemId: "item-uuid-2",
		itemSlug: "item-000002",
		status: "approved",
		approvedStartOn: "2026-10-05",
		approvedDueOn: "2026-10-12",
	}),
	readyForCheckout: true,
};
const checkedOut = loan({
	id: "out-1",
	itemId: "item-uuid-3",
	itemSlug: "item-000003",
	status: "checked_out",
	approvedStartOn: "2026-10-01",
	approvedDueOn: "2026-10-08",
});

function queueOf(
	partial: Partial<{
		requests: InventoryOperatorLoan[];
		handovers: InventoryOperatorLoanHandover[];
		returns: InventoryOperatorLoan[];
		maintenance: number;
	}> = {},
): InventoryOperatorLoanQueue {
	const requests = partial.requests ?? [requested];
	const handovers = partial.handovers ?? [approved];
	const returns = partial.returns ?? [checkedOut];
	const maintenance = Array.from(
		{ length: partial.maintenance ?? 0 },
		(_, i) => ({
			id: `m-${i}`,
			itemId: `item-m-${i}`,
			itemSlug: `item-m-${i}`,
			itemLabel: "Mask",
			startedAt: "2026-10-01T10:00:00Z",
			startedByPrincipalId: null,
			startReason: null,
		}),
	);
	return {
		pendingRequests: { count: requests.length, rows: requests },
		handoversDue: { count: handovers.length, rows: handovers },
		returnsAndOverdue: { count: returns.length, rows: returns },
		openMaintenance: { count: maintenance.length, rows: maintenance },
	};
}

type CommandVariables = { path: { loanId: string }; body?: object };

function harness(
	options: {
		queue?: InventoryOperatorLoanQueue;
		path?: string;
		requests?: LoanQueueBoardDeps["requests"];
		isDesktop?: boolean;
	} = {},
) {
	const queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false },
			mutations: { retry: false },
		},
	});
	let url = $state(new URL(options.path ?? BASE));
	let hover = $state<LoanQueueHover | undefined>();
	const navigations: string[] = [];
	const calls: { command: string; variables: CommandVariables }[] = [];
	const ok =
		(command: string) =>
		async (variables: CommandVariables): Promise<never> => {
			calls.push({ command, variables });
			// SAFETY: the controller ignores command responses.
			return { data: loan() } as never;
		};
	let created: LoanQueueBoard | undefined;
	const destroy = $effect.root(() => {
		created = createLoanQueueBoard({
			queryClient,
			url: () => url,
			navigate: (next) => {
				navigations.push(next.href);
				url = next;
			},
			isDesktop: () => options.isDesktop ?? true,
			hover: () => hover,
			requests: {
				queue: async () => ({ data: options.queue ?? queueOf() }),
				approve: ok("approve"),
				reject: ok("reject"),
				cancel: ok("cancel"),
				checkout: ok("checkout"),
				returnLoan: ok("returnLoan"),
				editDates: ok("editDates"),
				...options.requests,
			},
		});
	});
	if (!created) throw new Error("createLoanQueueBoard did not run");
	const board = created;
	cleanups.push(() => {
		destroy();
		queryClient.clear();
	});
	return {
		board,
		queryClient,
		calls,
		navigations,
		setHover: (next: LoanQueueHover | undefined) => {
			hover = next;
		},
		loaded: () => vi.waitFor(() => expect(board.buckets).toBeDefined()),
	};
}

const cleanups: (() => void)[] = [];
afterEach(() => {
	for (const cleanup of cleanups.splice(0)) cleanup();
});

describe("createLoanQueueBoard", () => {
	describe("default view", () => {
		it("lists every view with its bucket's count", async () => {
			const h = harness({ queue: queueOf({ returns: [], maintenance: 2 }) });
			await h.loaded();

			expect(h.board.views).toEqual([
				{ value: "requests", label: "Requests", count: 1 },
				{ value: "handovers", label: "Ready for handover", count: 1 },
				{ value: "returns", label: "Returns and overdue", count: 0 },
				{ value: "maintenance", label: "Open maintenance", count: 2 },
			]);
		});
		it("prefers requests, then returns, then handovers, then maintenance", async () => {
			const cases: [Parameters<typeof queueOf>[0], string][] = [
				[{}, "requests"],
				[{ requests: [] }, "returns"],
				[{ requests: [], returns: [] }, "handovers"],
				[
					{ requests: [], returns: [], handovers: [], maintenance: 1 },
					"maintenance",
				],
				[{ requests: [], returns: [], handovers: [] }, "requests"],
			];
			for (const [queue, expected] of cases) {
				const h = harness({ queue: queueOf(queue) });
				await h.loaded();
				expect(h.board.activeView).toBe(expected);
			}
		});

		it("honours a valid ?view= and ignores an unknown one", async () => {
			const valid = harness({ path: `${BASE}?view=maintenance` });
			await valid.loaded();
			expect(valid.board.activeView).toBe("maintenance");

			const invalid = harness({
				path: `${BASE}?view=everything`,
				queue: queueOf({ requests: [] }),
			});
			await invalid.loaded();
			expect(invalid.board.activeView).toBe("returns");
		});

		it("pushes ?view= on change and skips the current or unknown view", async () => {
			const h = harness();
			await h.loaded();

			h.board.changeView("requests");
			h.board.changeView("nonsense");
			expect(h.navigations).toEqual([]);

			h.board.changeView("handovers");
			expect(h.navigations).toEqual([`${BASE}?view=handovers`]);
			expect(h.board.activeView).toBe("handovers");
		});
	});

	describe("drop", () => {
		it("opens approve for a request dropped on handovers, without readyForCheckout", async () => {
			const h = harness();
			await h.loaded();

			h.board.drop("handovers", { loan: requested, readyForCheckout: true });

			expect(h.board.selection?.loan.id).toBe("req-1");
			expect(h.board.selection?.readyForCheckout).toBe(false);
			expect(h.board.selection?.startsOn).toBe("2026-10-10");
			expect(h.board.selection?.dueOn).toBe("2026-10-17");
		});

		it("opens checkout for an approved loan dropped on returns and forwards readyForCheckout", async () => {
			const h = harness();
			await h.loaded();

			h.board.drop("returns", { loan: approved, readyForCheckout: true });

			expect(h.board.selection?.loan.id).toBe("app-1");
			expect(h.board.selection?.readyForCheckout).toBe(true);
			expect(h.board.selection?.startsOn).toBe("2026-10-05");
		});

		it("resolves a card:<id> target to that card's column", async () => {
			const h = harness();
			await h.loaded();

			// out-1 sits in returns: dropping an approved loan on it is checkout.
			h.board.drop("card:out-1", { loan: approved, readyForCheckout: false });

			expect(h.board.selection?.loan.id).toBe("app-1");
			expect(h.board.selection?.readyForCheckout).toBe(false);
		});

		it("refuses a disallowed move with a notice and opens nothing", async () => {
			const h = harness();
			await h.loaded();

			h.board.drop("maintenance", { loan: requested });

			expect(h.board.selection).toBeUndefined();
			expect(h.board.notice).toMatch(/Maintenance holds items/);

			h.board.drop("requests", { loan: requested });
			expect(h.board.notice).toBeNull();
		});

		it("ignores a card target the queue does not know", async () => {
			const h = harness();
			await h.loaded();

			h.board.drop("card:missing", { loan: requested });

			expect(h.board.selection).toBeUndefined();
			expect(h.board.notice).toBeNull();
		});
	});

	describe("isInvalidHover", () => {
		it("is true only for the hovered column when the move would be refused", async () => {
			const h = harness();
			await h.loaded();

			expect(h.board.isInvalidHover("returns")).toBe(false);

			h.setHover({ targetContainer: "returns", dragged: { loan: requested } });
			expect(h.board.isInvalidHover("returns")).toBe(true);
			expect(h.board.isInvalidHover("handovers")).toBe(false);

			h.setHover({
				targetContainer: "handovers",
				dragged: { loan: requested },
			});
			expect(h.board.isInvalidHover("handovers")).toBe(false);

			// A card hover counts for the card's column.
			h.setHover({
				targetContainer: "card:out-1",
				dragged: { loan: requested },
			});
			expect(h.board.isInvalidHover("returns")).toBe(true);

			h.setHover({ targetContainer: "returns", dragged: undefined });
			expect(h.board.isInvalidHover("returns")).toBe(false);
		});
	});

	describe("canDrag", () => {
		it("allows requests and handovers on desktop only, never returns or overdue loans", async () => {
			const desktop = harness();
			expect(desktop.board.canDrag(requested, "request")).toBe(true);
			expect(desktop.board.canDrag(approved, "handover")).toBe(true);
			expect(desktop.board.canDrag(checkedOut, "return")).toBe(false);
			expect(
				desktop.board.canDrag({ ...approved, overdue: true }, "handover"),
			).toBe(false);

			const mobile = harness({ isDesktop: false });
			expect(mobile.board.canDrag(requested, "request")).toBe(false);
		});
	});

	describe("draft dates", () => {
		it("moving the start past the due date pulls the due date along", () => {
			const h = harness();
			h.board.open(requested);

			h.board.setStartsOn("2026-10-12");
			expect(h.board.selection?.startsOn).toBe("2026-10-12");
			expect(h.board.selection?.dueOn).toBe("2026-10-17");

			h.board.setStartsOn("2026-10-20");
			expect(h.board.selection?.startsOn).toBe("2026-10-20");
			expect(h.board.selection?.dueOn).toBe("2026-10-20");
		});

		it("a due date before the start is raised to the start", () => {
			const h = harness();
			h.board.open(requested);

			h.board.setDueOn("2026-10-14");
			expect(h.board.selection?.dueOn).toBe("2026-10-14");

			h.board.setDueOn("2026-10-01");
			expect(h.board.selection?.dueOn).toBe("2026-10-10");
		});

		it("does nothing without a selection", () => {
			const h = harness();

			h.board.setStartsOn("2026-10-12");
			h.board.setDueOn("2026-10-12");

			expect(h.board.selection).toBeUndefined();
		});
	});

	describe("commands", () => {
		it("builds each command body from the selection draft", async () => {
			const h = harness();
			await h.loaded();

			h.board.open(requested);
			h.board.selection!.startsOn = "2026-10-11";
			h.board.selection!.dueOn = "2026-10-20";
			h.board.selection!.note = "  bring it back clean  ";
			await h.board.approve();

			h.board.open(requested);
			h.board.selection!.note = "   ";
			await h.board.reject();

			h.board.open(approved);
			h.board.selection!.note = "member asked";
			await h.board.cancel();

			h.board.open(approved, true);
			await h.board.checkout();

			h.board.open(approved);
			h.board.selection!.dueOn = "2026-10-14";
			await h.board.editDates();

			h.board.open(checkedOut);
			h.board.selection!.dueOn = "2026-10-30";
			await h.board.editDates();

			h.board.open(checkedOut);
			await h.board.returnLoan();

			expect(h.calls).toEqual([
				{
					command: "approve",
					variables: {
						path: { loanId: "req-1" },
						body: {
							startsOn: "2026-10-11",
							dueOn: "2026-10-20",
							note: "bring it back clean",
						},
					},
				},
				{
					command: "reject",
					variables: { path: { loanId: "req-1" }, body: { note: undefined } },
				},
				{
					command: "cancel",
					variables: {
						path: { loanId: "app-1" },
						body: { note: "member asked" },
					},
				},
				{ command: "checkout", variables: { path: { loanId: "app-1" } } },
				{
					command: "editDates",
					variables: {
						path: { loanId: "app-1" },
						body: { startsOn: "2026-10-05", dueOn: "2026-10-14" },
					},
				},
				{
					command: "editDates",
					variables: {
						path: { loanId: "out-1" },
						body: { dueOn: "2026-10-30" },
					},
				},
				{ command: "returnLoan", variables: { path: { loanId: "out-1" } } },
			]);
		});

		it("does nothing without a selection", async () => {
			const h = harness();
			await h.loaded();

			await h.board.approve();

			expect(h.calls).toEqual([]);
		});

		it("on success clears the selection and invalidates the queue and the loan's Item queries", async () => {
			const h = harness();
			await h.loaded();
			const listKey = inventoryItemsListQueryKey({ query: { limit: 25 } });
			const showByIdKey = inventoryItemsShowQueryKey({
				path: { slugOrId: "item-uuid-1" },
			});
			const showBySlugKey = inventoryItemsShowQueryKey({
				path: { slugOrId: "item-000001" },
			});
			const otherItemKey = inventoryItemsShowQueryKey({
				path: { slugOrId: "item-000009" },
			});
			for (const key of [listKey, showByIdKey, showBySlugKey, otherItemKey]) {
				h.queryClient.setQueryData(key, { data: {} });
			}

			h.board.open(requested);
			await h.board.approve();

			expect(h.board.selection).toBeUndefined();
			expect(h.board.error).toBeNull();
			const invalidated = (key: readonly unknown[]) =>
				h.queryClient.getQueryState(key)?.isInvalidated;
			// The queue refetches at once because it is observed; a refetch
			// happened if it was fetched more than once.
			await vi.waitFor(() =>
				expect(
					h.queryClient.getQueryState(inventoryOperatorLoanQueueShowQueryKey())
						?.dataUpdateCount,
				).toBe(2),
			);
			expect(invalidated(listKey)).toBe(true);
			expect(invalidated(showByIdKey)).toBe(true);
			expect(invalidated(showBySlugKey)).toBe(true);
			expect(invalidated(otherItemKey)).toBe(false);
		});

		it("on error keeps the selection and shows Phoenix's detail", async () => {
			const h = harness({
				requests: {
					checkout: async () => {
						throw { errors: { detail: "The loan window has lapsed." } };
					},
				},
			});
			await h.loaded();

			h.board.open(approved, true);
			await h.board.checkout();

			expect(h.board.selection?.loan.id).toBe("app-1");
			expect(h.board.error).toBe("The loan window has lapsed.");
			await vi.waitFor(() => expect(h.board.busy).toBe(false));
		});

		it("falls back to the per-command text when the error has no detail", async () => {
			const h = harness({
				requests: {
					returnLoan: async () => {
						throw new TypeError("Failed to fetch");
					},
				},
			});
			await h.loaded();

			h.board.open(checkedOut);
			await h.board.returnLoan();

			expect(h.board.error).toBe("Could not record return");

			// Reopening clears the stale error.
			h.board.open(checkedOut);
			expect(h.board.error).toBeNull();
		});

		it("busy covers every one of the six commands", async () => {
			const commands = [
				["approve", requested],
				["reject", requested],
				["cancel", approved],
				["checkout", approved],
				["returnLoan", checkedOut],
				["editDates", approved],
			] as const;
			for (const [command, selected] of commands) {
				let finish = () => {};
				const pending = () =>
					new Promise<never>((resolve) => {
						// SAFETY: the controller ignores command responses.
						finish = () => resolve({ data: selected } as never);
					});
				const h = harness({ requests: { [command]: pending } });
				await h.loaded();

				h.board.open(selected);
				const running = h.board[command]();
				await vi.waitFor(() => expect(h.board.busy).toBe(true));
				expect(h.board.pending[command]).toBe(true);

				// A second command is refused while one is in flight.
				await h.board.reject();
				expect(h.calls.filter((call) => call.command === "reject")).toEqual([]);

				finish();
				await running;
				await vi.waitFor(() => expect(h.board.busy).toBe(false));
			}
		});
	});
});
