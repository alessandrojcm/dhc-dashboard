/**
 * Runes controller for the operator loan queue board (ALE-359).
 *
 * Owns everything on the board that is not markup: the queue read, the
 * default-view / `?view=` rule, the action-sheet selection and its draft,
 * drop-target resolution and the drop decision, and the six loan commands
 * with their freshness and error policy. It holds no XState actor:
 * `decideLoanDrop` stays a pure decision it calls. Phoenix stays the only
 * authority on loan state — a drop never writes, it opens the action sheet,
 * whose command is the single write path.
 *
 * Drag-and-drop (`@thisux/sveltednd`), the media query, and DOM focus stay in
 * the page; the controller takes plain inputs so it is testable without them.
 */
import { goto } from "$app/navigation";
import { page } from "$app/state";
import {
	createMutation,
	createQuery,
	useQueryClient,
	type QueryClient,
} from "@tanstack/svelte-query";
import {
	type InventoryOperatorLoan,
	type InventoryOperatorLoanQueue,
	type InventoryOperatorLoanQueueShowResponse,
	type InventoryOperatorLoansApproveData,
	type InventoryOperatorLoansApproveResponse,
	type InventoryOperatorLoansCancelData,
	type InventoryOperatorLoansCancelResponse,
	type InventoryOperatorLoansCheckoutData,
	type InventoryOperatorLoansCheckoutResponse,
	type InventoryOperatorLoansEditDatesData,
	type InventoryOperatorLoansEditDatesResponse,
	type InventoryOperatorLoansRejectData,
	type InventoryOperatorLoansRejectResponse,
	type InventoryOperatorLoansReturnData,
	type InventoryOperatorLoansReturnResponse,
	type Options,
	inventoryItemsListQueryKey,
	inventoryItemsShowQueryKey,
	inventoryOperatorLoanQueueShowOptions,
	inventoryOperatorLoanQueueShowQueryKey,
	inventoryOperatorLoansApproveMutation,
	inventoryOperatorLoansCancelMutation,
	inventoryOperatorLoansCheckoutMutation,
	inventoryOperatorLoansEditDatesMutation,
	inventoryOperatorLoansRejectMutation,
	inventoryOperatorLoansReturnMutation,
} from "@dhc/api-client";
import { apiErrorMessage } from "#lib/api-error.js";
import {
	decideLoanDrop,
	type LoanQueueDropTarget,
} from "#lib/components/inventory/loan-queue-dnd.js";

export type QueueView = "requests" | "handovers" | "returns" | "maintenance";

export type LoanCardKind = "request" | "handover" | "return";

/** What a card carries as drag data. */
export type LoanDragData = {
	loan: InventoryOperatorLoan;
	readyForCheckout?: boolean;
};

/** The drag currently in progress, as the page's drag library reports it. */
export type LoanQueueHover = {
	/** Droppable container id under the pointer: a column or `card:<loanId>`. */
	targetContainer: string | null;
	dragged: LoanDragData | undefined;
};

export type LoanQueueSelection = {
	loan: InventoryOperatorLoan;
	/** Advisory: only ever true when opened from a ready handover row. */
	readyForCheckout: boolean;
	/** Draft dates (`YYYY-MM-DD`) and note the commands are built from. */
	startsOn: string;
	dueOn: string;
	note: string;
};

type Request<TData, TResponse> = (options: TData) => Promise<TResponse>;

/** Request functions; each defaults to the generated Phoenix client. */
export type LoanQueueBoardRequests = {
	queue: () => Promise<InventoryOperatorLoanQueueShowResponse>;
	approve: Request<
		Options<InventoryOperatorLoansApproveData>,
		InventoryOperatorLoansApproveResponse
	>;
	reject: Request<
		Options<InventoryOperatorLoansRejectData>,
		InventoryOperatorLoansRejectResponse
	>;
	cancel: Request<
		Options<InventoryOperatorLoansCancelData>,
		InventoryOperatorLoansCancelResponse
	>;
	checkout: Request<
		Options<InventoryOperatorLoansCheckoutData>,
		InventoryOperatorLoansCheckoutResponse
	>;
	returnLoan: Request<
		Options<InventoryOperatorLoansReturnData>,
		InventoryOperatorLoansReturnResponse
	>;
	editDates: Request<
		Options<InventoryOperatorLoansEditDatesData>,
		InventoryOperatorLoansEditDatesResponse
	>;
};

export type LoanQueueBoardDeps = {
	/** Defaults to the client from Svelte context. */
	queryClient?: QueryClient;
	requests?: Partial<LoanQueueBoardRequests>;
	/** URL source for `?view=`; defaults to `page.url` from `$app/state`. */
	url?: () => URL;
	/** Pushes a history entry; defaults to `goto` from `$app/navigation`. */
	navigate?: (url: URL) => void | Promise<void>;
	/** The `lg` media-query result; drag only exists on the wide board. */
	isDesktop?: () => boolean;
	/** The drag in progress, if any. */
	hover?: () => LoanQueueHover | undefined;
};

/**
 * The one mapping between board views and queue buckets, in board order.
 * `holdsLoans` is false for maintenance: its rows are items, not loans, so a
 * `card:<id>` drop target never resolves there.
 */
const VIEW_BUCKETS = [
	{
		view: "requests",
		bucket: "pendingRequests",
		label: "Requests",
		holdsLoans: true,
	},
	{
		view: "handovers",
		bucket: "handoversDue",
		label: "Ready for handover",
		holdsLoans: true,
	},
	{
		view: "returns",
		bucket: "returnsAndOverdue",
		label: "Returns and overdue",
		holdsLoans: true,
	},
	{
		view: "maintenance",
		bucket: "openMaintenance",
		label: "Open maintenance",
		holdsLoans: false,
	},
] as const satisfies readonly {
	view: QueueView;
	bucket: keyof InventoryOperatorLoanQueue;
	label: string;
	holdsLoans: boolean;
}[];

/** Default view: the first non-empty bucket in this order, else requests. */
const DEFAULT_VIEW_PRIORITY = [
	"requests",
	"returns",
	"handovers",
	"maintenance",
] as const satisfies readonly QueueView[];

export function parseQueueView(value: string | null): QueueView | undefined {
	return VIEW_BUCKETS.find((entry) => entry.view === value)?.view;
}

function bucketFor(view: QueueView) {
	// SAFETY: VIEW_BUCKETS lists every QueueView, so the lookup always hits.
	return VIEW_BUCKETS.find((entry) => entry.view === view)!.bucket;
}

function trimmedNote(note: string): string | undefined {
	return note.trim() || undefined;
}

export function createLoanQueueBoard(deps: LoanQueueBoardDeps = {}) {
	const queryClient = deps.queryClient ?? useQueryClient();
	const client = () => queryClient;
	const requests = deps.requests ?? {};
	const url = deps.url ?? (() => page.url);
	const navigate =
		deps.navigate ?? ((next: URL) => goto(next, { reset: false }));
	const isDesktop = deps.isDesktop ?? (() => false);
	const hover = deps.hover ?? (() => undefined);

	let selection = $state<LoanQueueSelection | undefined>();
	let error = $state<string | null>(null);
	let notice = $state<string | null>(null);

	const queue = createQuery(
		() => ({
			...inventoryOperatorLoanQueueShowOptions(),
			...(requests.queue && { queryFn: requests.queue }),
			select: (response: InventoryOperatorLoanQueueShowResponse) =>
				response.data,
		}),
		client,
	);

	const buckets = $derived(queue.data);

	const views = $derived(
		VIEW_BUCKETS.map(({ view, bucket, label }) => ({
			value: view,
			label,
			count: buckets?.[bucket].count ?? 0,
		})),
	);

	const defaultView = $derived<QueueView>(
		DEFAULT_VIEW_PRIORITY.find((view) => buckets?.[bucketFor(view)].count) ??
			"requests",
	);
	const activeView = $derived(
		parseQueueView(url().searchParams.get("view")) ?? defaultView,
	);

	function changeView(value: string) {
		const view = parseQueueView(value);
		if (!view || view === activeView) return;
		const next = new URL(url().href);
		next.searchParams.set("view", view);
		void navigate(next);
	}

	function open(loan: InventoryOperatorLoan, readyForCheckout = false) {
		selection = {
			loan,
			readyForCheckout,
			startsOn: loan.approvedStartOn ?? loan.requestedStartOn,
			dueOn: loan.approvedDueOn ?? loan.requestedDueOn,
			note: "",
		};
		error = null;
	}

	function close() {
		selection = undefined;
		error = null;
	}

	/** Sets the draft start; a due date before it moves up to the start. */
	function setStartsOn(value: string) {
		if (!selection) return;
		selection.startsOn = value;
		if (selection.dueOn < value) selection.dueOn = value;
	}

	/** Sets the draft due date, never earlier than the draft start. */
	function setDueOn(value: string) {
		if (!selection) return;
		selection.dueOn =
			selection.startsOn && value < selection.startsOn
				? selection.startsOn
				: value;
	}

	function columnForLoanId(id: string): LoanQueueDropTarget | undefined {
		const current = buckets;
		if (!current) return undefined;
		return VIEW_BUCKETS.find(
			({ bucket, holdsLoans }) =>
				holdsLoans &&
				current[bucket].rows.some((row: { id: string }) => row.id === id),
		)?.view;
	}

	function resolveDropTarget(
		targetContainer: string,
	): LoanQueueDropTarget | undefined {
		const view = parseQueueView(targetContainer);
		if (view) return view;
		if (targetContainer.startsWith("card:")) {
			return columnForLoanId(targetContainer.slice("card:".length));
		}
		return undefined;
	}

	/**
	 * React to a drop. An allowed move opens the action sheet (forwarding
	 * `readyForCheckout` only for checkout); a refused move sets `notice`.
	 */
	function drop(targetContainer: string, dragged: LoanDragData) {
		const toColumn = resolveDropTarget(targetContainer);
		if (!toColumn) return;
		const outcome = decideLoanDrop({
			fromStatus: dragged.loan.status,
			toColumn,
			readyForCheckout: dragged.readyForCheckout,
		});
		if (outcome.kind === "openAction") {
			notice = null;
			open(
				dragged.loan,
				outcome.action === "checkout"
					? (dragged.readyForCheckout ?? false)
					: false,
			);
		} else if (outcome.kind === "ignored") {
			notice = null;
		} else {
			notice = outcome.reason;
		}
	}

	/**
	 * Whether `column` is hovered with a loan the drop decision would not act
	 * on. Card hovers resolve through their column.
	 */
	function isInvalidHover(column: LoanQueueDropTarget): boolean {
		const current = hover();
		if (!current?.targetContainer || !current.dragged?.loan) return false;
		const toColumn = resolveDropTarget(current.targetContainer);
		if (toColumn !== column) return false;
		return (
			decideLoanDrop({
				fromStatus: current.dragged.loan.status,
				toColumn,
				readyForCheckout: current.dragged.readyForCheckout,
			}).kind !== "openAction"
		);
	}

	/**
	 * Returns carry `checked_out` loans, which have no forward column, and
	 * overdue loans cannot move either; neither can drag. Drag also needs the
	 * wide board.
	 */
	function canDrag(loan: InventoryOperatorLoan, kind: LoanCardKind): boolean {
		if (kind === "return" || loan.overdue) return false;
		return isDesktop();
	}

	function invalidate(loan: InventoryOperatorLoan | undefined) {
		const keys = [
			inventoryOperatorLoanQueueShowQueryKey(),
			// Partial key: matches every operator Item list, filtered or infinite.
			inventoryItemsListQueryKey(),
			...(loan
				? [loan.itemId, loan.itemSlug].map((slugOrId) =>
						inventoryItemsShowQueryKey({ path: { slugOrId } }),
					)
				: []),
		];
		return Promise.all(
			keys.map((queryKey) => queryClient.invalidateQueries({ queryKey })),
		);
	}

	const approveMutation = createMutation(
		() => ({
			...inventoryOperatorLoansApproveMutation(),
			...(requests.approve && { mutationFn: requests.approve }),
		}),
		client,
	);
	const rejectMutation = createMutation(
		() => ({
			...inventoryOperatorLoansRejectMutation(),
			...(requests.reject && { mutationFn: requests.reject }),
		}),
		client,
	);
	const cancelMutation = createMutation(
		() => ({
			...inventoryOperatorLoansCancelMutation(),
			...(requests.cancel && { mutationFn: requests.cancel }),
		}),
		client,
	);
	const checkoutMutation = createMutation(
		() => ({
			...inventoryOperatorLoansCheckoutMutation(),
			...(requests.checkout && { mutationFn: requests.checkout }),
		}),
		client,
	);
	const returnMutation = createMutation(
		() => ({
			...inventoryOperatorLoansReturnMutation(),
			...(requests.returnLoan && { mutationFn: requests.returnLoan }),
		}),
		client,
	);
	const editDatesMutation = createMutation(
		() => ({
			...inventoryOperatorLoansEditDatesMutation(),
			...(requests.editDates && { mutationFn: requests.editDates }),
		}),
		client,
	);

	const busy = $derived(
		approveMutation.isPending ||
			rejectMutation.isPending ||
			cancelMutation.isPending ||
			checkoutMutation.isPending ||
			returnMutation.isPending ||
			editDatesMutation.isPending,
	);

	/**
	 * Runs one command built from the selection draft. Success closes the
	 * sheet and marks the queue and the loan's Item reads stale; failure keeps
	 * the sheet open with Phoenix's detail, or `fallback`. Never throws.
	 */
	async function run<TVariables, TResult>(
		mutation: { mutateAsync: (variables: TVariables) => Promise<TResult> },
		fallback: string,
		build: (current: LoanQueueSelection) => TVariables,
	) {
		if (!selection || busy) return;
		const { loan } = selection;
		error = null;
		try {
			await mutation.mutateAsync(build(selection));
		} catch (cause) {
			error = apiErrorMessage(cause, fallback);
			return;
		}
		close();
		await invalidate(loan);
	}

	return {
		queue,
		get buckets() {
			return buckets;
		},
		get views() {
			return views;
		},
		get activeView() {
			return activeView;
		},
		changeView,
		/**
		 * The open action sheet's loan and draft. `note` is writable; dates go
		 * through `setStartsOn` / `setDueOn` so due never precedes start.
		 */
		get selection() {
			return selection;
		},
		get busy() {
			return busy;
		},
		/** Inline action-sheet error for the last failed command. */
		get error() {
			return error;
		},
		/** Why the last drop was refused, for the board's status line. */
		get notice() {
			return notice;
		},
		/** Which command is in flight, for button labels. */
		get pending() {
			return {
				approve: approveMutation.isPending,
				reject: rejectMutation.isPending,
				cancel: cancelMutation.isPending,
				checkout: checkoutMutation.isPending,
				returnLoan: returnMutation.isPending,
				editDates: editDatesMutation.isPending,
			};
		},
		open,
		close,
		setStartsOn,
		setDueOn,
		drop,
		isInvalidHover,
		canDrag,
		approve: () =>
			run(
				approveMutation,
				"Could not approve this request",
				({ loan, startsOn, dueOn, note }) => ({
					path: { loanId: loan.id },
					body: { startsOn, dueOn, note: trimmedNote(note) },
				}),
			),
		reject: () =>
			run(
				rejectMutation,
				"Could not reject this request",
				({ loan, note }) => ({
					path: { loanId: loan.id },
					body: { note: trimmedNote(note) },
				}),
			),
		cancel: () =>
			run(cancelMutation, "Could not cancel this loan", ({ loan, note }) => ({
				path: { loanId: loan.id },
				body: { note: trimmedNote(note) },
			})),
		checkout: () =>
			run(checkoutMutation, "Could not record checkout", ({ loan }) => ({
				path: { loanId: loan.id },
			})),
		returnLoan: () =>
			run(returnMutation, "Could not record return", ({ loan }) => ({
				path: { loanId: loan.id },
			})),
		/** Approved loans edit both dates; checked-out loans only the due date. */
		editDates: () =>
			run(
				editDatesMutation,
				"Could not update loan dates",
				({ loan, startsOn, dueOn }) => ({
					path: { loanId: loan.id },
					body: loan.status === "approved" ? { startsOn, dueOn } : { dueOn },
				}),
			),
	};
}

export type LoanQueueBoard = ReturnType<typeof createLoanQueueBoard>;
