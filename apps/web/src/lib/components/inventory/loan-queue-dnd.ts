import { initialTransition, setup } from "xstate";

/**
 * Pure drop decision for the operator loan queue kanban (ALE-286 buckets).
 *
 * Maps one drag (`fromStatus` of the dragged loan + target column) onto an
 * explicit outcome. It runs through XState's pure `initialTransition` only —
 * no actor is ever created — so there is nothing to leak across components.
 * Phoenix remains the only authority on durable state; this machine decides
 * *how the board reacts* to a drop: which sheet to open, or why to refuse.
 *
 * Allowed forward moves mirror `Dhc.Inventory.OperatorLoans`:
 * `requested → approved` (approve) and `approved → checked_out` (checkout).
 * A drop never mutates: an allowed drop opens the existing action sheet for
 * that loan (which already carries the approve / checkout / return forms),
 * and the TanStack mutation inside the sheet stays the single write path.
 *
 * Deliberately refused:
 * - Same-column drops: queue order is server-owned (oldest / earliest-due
 *   first), so there is no reorder to express.
 * - Anything onto `maintenance`: those rows are items with open maintenance
 *   periods, not loans — there is no loan transition into that bucket.
 * - Backwards / sideways moves (`approved → requests`, `checked_out`
 *   anywhere): there is no un-approve or un-checkout transition.
 * - `checked_out` has no forward column: `returned` loans leave the queue,
 *   so recording a return stays on the card's "Record return" button.
 */

export type LoanQueueColumn = "requests" | "handovers" | "returns";
export type LoanQueueMaintenanceColumn = "maintenance";
export type LoanQueueDropTarget = LoanQueueColumn | LoanQueueMaintenanceColumn;

export type LoanStatus =
	| "requested"
	| "approved"
	| "checked_out"
	| "rejected"
	| "cancelled"
	| "returned";

export type LoanQueueDropInput = {
	fromStatus: LoanStatus;
	toColumn: LoanQueueDropTarget;
	/** Advisory `readyForCheckout` from the handover row, if known. */
	readyForCheckout?: boolean;
};

export type LoanQueueDropOutcome =
	| {
			kind: "openAction";
			action: "approve" | "checkout";
			/** Forwarded so the sheet can warn before the operator confirms. */
			readyForCheckout: boolean | undefined;
	  }
	| { kind: "ignored"; reason: "sameColumn" }
	| { kind: "rejected"; reason: string };

type DropContext = {
	fromStatus: LoanStatus;
	toColumn: LoanQueueDropTarget;
	readyForCheckout: boolean | undefined;
};

const loanQueueDropMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as DropContext,
		input: {} as LoanQueueDropInput,
		output: {} as LoanQueueDropOutcome,
	},
	guards: {
		isSameColumn: ({ context }) => {
			if (context.fromStatus === "requested")
				return context.toColumn === "requests";
			if (context.fromStatus === "approved")
				return context.toColumn === "handovers";
			if (context.fromStatus === "checked_out")
				return context.toColumn === "returns";
			return false;
		},
		isMaintenanceTarget: ({ context }) => context.toColumn === "maintenance",
		isApproveMove: ({ context }) =>
			context.fromStatus === "requested" && context.toColumn === "handovers",
		isCheckoutMove: ({ context }) =>
			context.fromStatus === "approved" && context.toColumn === "returns",
	},
}).createMachine({
	id: "loanQueueDrop",
	context: ({ input }) => ({
		fromStatus: input.fromStatus,
		toColumn: input.toColumn,
		readyForCheckout: input.readyForCheckout,
	}),
	initial: "evaluating",
	states: {
		evaluating: {
			always: [
				{ guard: "isSameColumn", target: "sameColumn" },
				{ guard: "isApproveMove", target: "approve" },
				{ guard: "isCheckoutMove", target: "checkout" },
				{ guard: "isMaintenanceTarget", target: "maintenanceRefused" },
				{ target: "refused" },
			],
		},
		approve: {
			type: "final",
			output: ({ context }) => ({
				kind: "openAction" as const,
				action: "approve" as const,
				readyForCheckout: context.readyForCheckout,
			}),
		},
		checkout: {
			type: "final",
			output: ({ context }) => ({
				kind: "openAction" as const,
				action: "checkout" as const,
				readyForCheckout: context.readyForCheckout,
			}),
		},
		sameColumn: {
			type: "final",
			output: () => ({
				kind: "ignored" as const,
				reason: "sameColumn" as const,
			}),
		},
		maintenanceRefused: {
			type: "final",
			output: () => ({
				kind: "rejected" as const,
				reason:
					"Maintenance holds items, not loans: record the handover or return first.",
			}),
		},
		refused: {
			type: "final",
			output: ({ context }) => ({
				kind: "rejected" as const,
				reason: refusalReason(context.fromStatus, context.toColumn),
			}),
		},
	},
	// SAFETY: every final state above declares an `output` of type
	// `LoanQueueDropOutcome`; the root output only forwards the done-state event's.
	output: ({ event }) => event.output as LoanQueueDropOutcome,
});

function refusalReason(
	fromStatus: LoanStatus,
	toColumn: LoanQueueDropTarget,
): string {
	if (fromStatus === "checked_out") {
		return "Checked-out loans leave the queue through “Record return”: there is no further column to drag to.";
	}
	if (fromStatus === "approved") {
		return toColumn === "requests"
			? "An approved loan cannot go back to Requests: cancel it from the action panel instead."
			: "An approved loan moves to Returns through checkout only.";
	}
	if (fromStatus === "requested") {
		return toColumn === "returns"
			? "A request needs approval before handover: drag it to Ready for handover first."
			: "Requests move to Ready for handover through approval.";
	}
	return "That move is not a loan transition: use the action panel.";
}

/**
 * Decide how the board reacts to a drop. Pure: the same input always yields
 * the same outcome.
 */
export function decideLoanDrop(
	input: LoanQueueDropInput,
): LoanQueueDropOutcome {
	const [snapshot] = initialTransition(loanQueueDropMachine, input);
	if (snapshot.status !== "done" || !snapshot.output) {
		throw new Error("loanQueueDropMachine did not reach an outcome");
	}
	return snapshot.output;
}

/**
 * One intentional hint per drop outcome for the board's status line. The
 * record is exhaustive on purpose (a new outcome without decided copy is a
 * type error).
 */
export const loanQueueDropHint = {
	openAction: "Opening the action panel to confirm.",
	ignored: "Already in this column — the queue order is set by the server.",
	rejected: "That move is not allowed.",
} satisfies Record<LoanQueueDropOutcome["kind"], string>;
