import { assign, fromPromise, setup } from "xstate";

/**
 * Component-scoped UI machine for the payment step of Invitation Acceptance
 * (GH-509). It models the *browser's* asynchronous work — loading the Stripe
 * Payment Element, producing a confirmation token, handing the form to the
 * server, and reacting to the server's answer — as explicit states.
 *
 * It is not a source of truth: Phoenix owns payment state and idempotency, and
 * a successful submission leaves this page by redirect, so the machine has no
 * "accepted" state. Instantiate it per component with `useMachine`; never at
 * module scope, and never hydrate a snapshot with an active invocation.
 */

export type PaymentFailure = {
	message: string;
	/** `false` when the acceptance proof is gone and the invitee must verify again. */
	recoverable: boolean;
};

export type PaymentMachineInput = {
	complimentary: boolean;
};

export type PaymentMachineContext = {
	complimentary: boolean;
	confirmationToken: string | undefined;
	failure: PaymentFailure | undefined;
};

export type PaymentMachineEvent =
	| { type: "PAYMENT_REQUESTED" }
	| { type: "SUBMISSION_FAILED"; message: string; recoverable: boolean }
	| { type: "RETRY_REQUESTED" };

export type PreparedPayment = { confirmationToken: string | undefined };

export const paymentMachineStates = [
	"deciding",
	"initializing",
	"ready",
	"preparing",
	"submitting",
	"failed",
	"expired",
	"unavailable",
] as const;

export type PaymentMachineState = (typeof paymentMachineStates)[number];

/** Implementations a host component provides through `paymentMachine.provide`. */
export type PaymentMachineImplementations = {
	/** Mount the Stripe Payment Element and resolve once it reports `ready`. */
	loadPaymentElement: () => Promise<void>;
	/** Validate the element and create the Stripe confirmation token. */
	preparePayment: (input: {
		complimentary: boolean;
	}) => Promise<PreparedPayment>;
	/** Hand the prepared payment to the server (submit the remote form). */
	submitPayment: (params: PreparedPayment) => void;
};

function messageOf(cause: unknown, fallback: string): string {
	return cause instanceof Error && cause.message ? cause.message : fallback;
}

export const paymentMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as PaymentMachineContext,
		events: {} as PaymentMachineEvent,
		input: {} as PaymentMachineInput,
	},
	actors: {
		loadPaymentElement: fromPromise<void, void>(async () => {
			throw new Error("loadPaymentElement must be provided by the host");
		}),
		preparePayment: fromPromise<PreparedPayment, { complimentary: boolean }>(
			async () => {
				throw new Error("preparePayment must be provided by the host");
			},
		),
	},
	actions: {
		submitPayment: (_, _params: PreparedPayment) => {},
	},
	guards: {
		isComplimentary: ({ context }) => context.complimentary,
		isRecoverable: ({ event }) =>
			event.type === "SUBMISSION_FAILED" && event.recoverable,
	},
}).createMachine({
	id: "invitationPayment",
	context: ({ input }) => ({
		complimentary: input.complimentary,
		confirmationToken: undefined,
		failure: undefined,
	}),
	initial: "deciding",
	states: {
		deciding: {
			always: [
				{ guard: "isComplimentary", target: "ready" },
				{ target: "initializing" },
			],
		},
		initializing: {
			invoke: {
				src: "loadPaymentElement",
				onDone: { target: "ready" },
				onError: {
					target: "unavailable",
					actions: assign({
						failure: ({ event }) => ({
							message: messageOf(
								event.error,
								"The payment form could not be loaded.",
							),
							recoverable: true,
						}),
					}),
				},
			},
		},
		ready: {
			on: {
				PAYMENT_REQUESTED: { target: "preparing" },
			},
		},
		preparing: {
			invoke: {
				src: "preparePayment",
				input: ({ context }) => ({ complimentary: context.complimentary }),
				onDone: {
					target: "submitting",
					actions: assign({
						confirmationToken: ({ event }) => event.output.confirmationToken,
					}),
				},
				onError: {
					target: "failed",
					actions: assign({
						failure: ({ event }) => ({
							message: messageOf(
								event.error,
								"Failed to create payment confirmation. Please try again.",
							),
							recoverable: true,
						}),
					}),
				},
			},
		},
		submitting: {
			entry: {
				type: "submitPayment",
				params: ({ context }) => ({
					confirmationToken: context.confirmationToken,
				}),
			},
			on: {
				SUBMISSION_FAILED: [
					{
						guard: "isRecoverable",
						target: "failed",
						actions: assign({
							failure: ({ event }) => ({
								message: event.message,
								recoverable: true,
							}),
						}),
					},
					{
						target: "expired",
						actions: assign({
							failure: ({ event }) => ({
								message: event.message,
								recoverable: false,
							}),
						}),
					},
				],
			},
		},
		failed: {
			on: {
				RETRY_REQUESTED: {
					target: "ready",
					actions: assign({ failure: undefined, confirmationToken: undefined }),
				},
				PAYMENT_REQUESTED: {
					target: "preparing",
					actions: assign({ failure: undefined, confirmationToken: undefined }),
				},
			},
		},
		// The proof is gone; only re-verifying (a full page load) continues.
		expired: {},
		unavailable: {
			on: {
				RETRY_REQUESTED: {
					target: "initializing",
					actions: assign({ failure: undefined }),
				},
			},
		},
	},
});

export type PaymentSubmitPresentation = {
	/** Whether the primary button is disabled in this state. */
	disabled: boolean;
	/** Whether the primary button shows a spinner. */
	busy: boolean;
	/** Accessible status line announced to the invitee, if any. */
	status: string | undefined;
};

/**
 * One intentional presentation per machine state for the submit control. The
 * record is exhaustive on purpose (adding a state without deciding its UI is a
 * type error). Failure copy comes from `context.failure`, not from here.
 */
export const paymentSubmitPresentation = {
	deciding: { disabled: true, busy: false, status: undefined },
	initializing: {
		disabled: true,
		busy: false,
		status: "Loading the secure payment form…",
	},
	ready: { disabled: false, busy: false, status: undefined },
	preparing: {
		disabled: true,
		busy: true,
		status: "Checking your payment details…",
	},
	submitting: {
		disabled: true,
		busy: true,
		status: "Completing your membership. Do not close this page.",
	},
	failed: { disabled: false, busy: false, status: undefined },
	expired: { disabled: true, busy: false, status: undefined },
	unavailable: { disabled: true, busy: false, status: undefined },
} satisfies Record<PaymentMachineState, PaymentSubmitPresentation>;
