import type {
	MembershipReactivateAnnualFeeMode,
	MembershipReactivatePaymentState,
	MembershipReactivateResponse,
	MembershipReactivationPreviewResponse,
} from "@dhc/api-client";
import { assign, fromPromise, setup, type SnapshotFrom } from "xstate";
import { apiProblem } from "#lib/api-error.js";

/**
 * Component-scoped interaction protocol of the membership reactivation dialog
 * (ALE-450): saved-method lookup, selection, submission, the billing-portal
 * fallback, outcome reporting and reconciliation.
 *
 * TanStack Query stays the server-state owner: the injected actors are the
 * generated preview query (through the query client) and the generated
 * reactivate / billing-portal mutations, and the amounts preview stays a
 * query the host keys off `context.selection`. The machine never caches a
 * server read for display beyond the one preview this dialog opened with.
 *
 * Instantiate it per dialog and member with `useMachine`; stopping it
 * (closing the dialog, or the host replacing the member) discards every late
 * result. A stopped actor does not undo a reactivation Phoenix already
 * accepted, so a submission cannot be dismissed: `CLOSE` is ignored while it
 * is in flight.
 *
 * Billing dates are never worked out here: the start-date window comes from
 * `reactivation-start-window.ts` (the host passes its first day as the
 * initial selection) and Phoenix returns the billing anchors.
 */

export type ReactivationPreview = MembershipReactivationPreviewResponse["data"];
export type SavedPaymentMethod = NonNullable<
	ReactivationPreview["savedPaymentMethod"]
>;
export type MembershipCoverage = ReactivationPreview["membershipCoverage"];
export type AnnualFeeMode = MembershipReactivateAnnualFeeMode;
export type ReactivationResult = MembershipReactivateResponse["data"];
/** Phoenix's off-session payment outcome; each one is its own final state. */
export type ReactivationOutcome = MembershipReactivatePaymentState;

/** The operator's agreement with the member: kept across failure and retry. */
export type ReactivationSelection = {
	/** `YYYY-MM-DD`, within the start window. */
	startDate: string;
	annualFeeMode: AnnualFeeMode;
};

export type ReactivationInput = {
	memberId: string;
	/** The start window's first day (`reactivationStartWindow().earliest`). */
	startDate: string;
};

export type ReactivationContext = {
	memberId: string;
	selection: ReactivationSelection;
	/** Known once the lookup answered; also shown by the portal fallback. */
	coverage: MembershipCoverage | null;
	method: SavedPaymentMethod | null;
	/** The last submission's refusal, shown inside the dialog. */
	problem: string | null;
};

export type ReactivationEvent =
	| ({ type: "SELECT" } & ReactivationSelection)
	| { type: "CONFIRM" }
	| { type: "OPEN_PORTAL" }
	| { type: "CLOSE" };

/** Implementations a host component provides through `reactivationMachine.provide`. */
export type ReactivationImplementations = {
	lookUpMethod: (input: { memberId: string }) => Promise<ReactivationPreview>;
	reactivate: (input: {
		memberId: string;
		selection: ReactivationSelection;
	}) => Promise<ReactivationResult>;
	openBillingPortal: (input: { memberId: string }) => Promise<{ url: string }>;
	/** Tell the operator how the charge went. */
	report: (outcome: ReactivationOutcome) => void;
	/** Reconcile the member, list, analytics and own-profile reads. */
	reconcile: (input: { memberId: string }) => void;
	/** Hand the Stripe-hosted portal URL to the browser. */
	showPortal: (input: { url: string }) => void;
	portalFailed: (input: { detail: string }) => void;
	/** The workflow is over (an outcome, or dismissed): close the dialog. */
	close: () => void;
};

const NO_SAVED_METHOD = "no_saved_payment_method";
const COMPLETE: MembershipCoverage = { monthly: "active", annual: "active" };
const LAPSED: MembershipCoverage = { monthly: "lapsed", annual: "lapsed" };

function unprovided(name: string) {
	return async (): Promise<never> => {
		throw new Error(`${name} must be provided by the host`);
	};
}

function finished(outcome: ReactivationOutcome) {
	return {
		type: "final" as const,
		entry: [
			{ type: "report" as const, params: () => outcome },
			"reconcile" as const,
			"close" as const,
		],
	};
}

export const reactivationMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as ReactivationContext,
		events: {} as ReactivationEvent,
		input: {} as ReactivationInput,
	},
	actors: {
		lookUpMethod: fromPromise<ReactivationPreview, { memberId: string }>(
			unprovided("lookUpMethod"),
		),
		reactivate: fromPromise<
			ReactivationResult,
			{ memberId: string; selection: ReactivationSelection }
		>(unprovided("reactivate")),
		openBillingPortal: fromPromise<{ url: string }, { memberId: string }>(
			unprovided("openBillingPortal"),
		),
	},
	actions: {
		select: assign({
			selection: ({ context, event }) =>
				event.type === "SELECT"
					? { startDate: event.startDate, annualFeeMode: event.annualFeeMode }
					: context.selection,
		}),
		report: (_, _outcome: ReactivationOutcome) => {},
		reconcile: () => {},
		showPortal: (_, _input: { url: string }) => {},
		portalFailed: (_, _input: { detail: string }) => {},
		close: () => {},
	},
	guards: {
		hasSavedMethod: (_, preview: ReactivationPreview) =>
			preview.savedPaymentMethod != null,
		/** Something to start, on a date the operator picked. */
		chargeable: ({ context }) =>
			context.selection.startDate !== "" &&
			!(
				context.coverage?.monthly === COMPLETE.monthly &&
				context.coverage.annual === COMPLETE.annual
			),
		paid: (_, state: ReactivationOutcome) => state === "succeeded",
		declined: (_, state: ReactivationOutcome) => state === "terminal",
		pending: (_, state: ReactivationOutcome) => state === "pending",
	},
}).createMachine({
	id: "reactivation",
	context: ({ input }) => ({
		memberId: input.memberId,
		selection: { startDate: input.startDate, annualFeeMode: "prorated_now" },
		coverage: null,
		method: null,
		problem: null,
	}),
	initial: "lookingUp",
	on: {
		// Dismissing stops whatever is in flight; its late result is dropped.
		CLOSE: { target: ".closed" },
	},
	states: {
		lookingUp: {
			invoke: {
				src: "lookUpMethod",
				input: ({ context }) => ({ memberId: context.memberId }),
				onDone: [
					{
						guard: {
							type: "hasSavedMethod",
							params: ({ event }) => event.output,
						},
						target: "ready",
						actions: assign({
							coverage: ({ event }) => event.output.membershipCoverage,
							method: ({ event }) => event.output.savedPaymentMethod ?? null,
						}),
					},
					{
						target: "noSavedMethod",
						actions: assign({
							coverage: ({ event }) => event.output.membershipCoverage,
						}),
					},
				],
				onError: { target: "lookupFailed" },
			},
		},
		// The lookup itself failed: nothing to charge against, and nothing was
		// charged. The operator closes and reopens to try again.
		lookupFailed: {},
		// Phoenix has no usable saved method (from the lookup, or as the
		// submission's refusal): the member restarts through the Stripe portal.
		noSavedMethod: {
			initial: "idle",
			states: {
				idle: { on: { OPEN_PORTAL: { target: "opening" } } },
				opening: {
					tags: ["openingPortal"],
					invoke: {
						src: "openBillingPortal",
						input: ({ context }) => ({ memberId: context.memberId }),
						onDone: {
							target: "idle",
							actions: {
								type: "showPortal",
								params: ({ event }) => ({ url: event.output.url }),
							},
						},
						onError: {
							target: "idle",
							actions: {
								type: "portalFailed",
								params: ({ event }) => ({
									detail:
										apiProblem(event.error)?.detail ??
										"Failed to open billing portal",
								}),
							},
						},
					},
				},
			},
		},
		ready: {
			initial: "selecting",
			states: {
				selecting: {
					on: {
						SELECT: { actions: "select" },
						CONFIRM: {
							guard: "chargeable",
							target: "submitting",
							actions: assign({ problem: null }),
						},
					},
				},
				submitting: {
					tags: ["submitting"],
					on: {
						// The charge may already be on its way: stay until Phoenix answers.
						CLOSE: {},
					},
					invoke: {
						src: "reactivate",
						input: ({ context }) => ({
							memberId: context.memberId,
							selection: context.selection,
						}),
						onDone: [
							{
								guard: {
									type: "paid",
									params: ({ event }) => event.output.paymentState,
								},
								target: "#reactivation.succeeded",
							},
							{
								guard: {
									type: "declined",
									params: ({ event }) => event.output.paymentState,
								},
								target: "#reactivation.terminal",
							},
							{
								guard: {
									type: "pending",
									params: ({ event }) => event.output.paymentState,
								},
								target: "#reactivation.pending",
							},
							{ target: "#reactivation.needsAction" },
						],
						onError: [
							{
								guard: ({ event }) =>
									apiProblem(event.error)?.code === NO_SAVED_METHOD,
								target: "#reactivation.noSavedMethod",
							},
							{
								// Back to the same selection, so a retry re-sends it.
								target: "selecting",
								actions: assign({
									problem: ({ event }) =>
										apiProblem(event.error)?.detail ??
										"Failed to reactivate membership",
								}),
							},
						],
					},
				},
			},
		},
		succeeded: finished("succeeded"),
		terminal: finished("terminal"),
		pending: finished("pending"),
		needsAction: finished("needs_action"),
		closed: { type: "final", entry: "close" },
	},
});

export type ReactivationSnapshot = SnapshotFrom<typeof reactivationMachine>;

/** What the modal renders: one phase at a time, plus the coverage it knows. */
export type ReactivationView = { coverage: MembershipCoverage } & (
	| { phase: "lookingUp" }
	| { phase: "lookupFailed" }
	| { phase: "noSavedMethod"; openingPortal: boolean }
	| {
			phase: "ready";
			method: SavedPaymentMethod;
			submitting: boolean;
			problem: string | null;
	  }
	/** An outcome or a dismissal: the host is closing the dialog. */
	| { phase: "finished" }
);

export function reactivationView(
	snapshot: ReactivationSnapshot,
): ReactivationView {
	const { coverage, method, problem } = snapshot.context;
	const known = coverage ?? LAPSED;
	if (snapshot.matches("lookingUp"))
		return { phase: "lookingUp", coverage: known };
	if (snapshot.matches("lookupFailed"))
		return { phase: "lookupFailed", coverage: known };
	if (snapshot.matches("noSavedMethod"))
		return {
			phase: "noSavedMethod",
			coverage: known,
			openingPortal: snapshot.hasTag("openingPortal"),
		};
	if (snapshot.matches("ready") && method)
		return {
			phase: "ready",
			coverage: known,
			method,
			submitting: snapshot.hasTag("submitting"),
			problem,
		};
	return { phase: "finished", coverage: known };
}
