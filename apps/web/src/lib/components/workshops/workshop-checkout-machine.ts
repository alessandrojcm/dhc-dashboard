import { assign, fromPromise, setup } from "xstate";

/**
 * Component-scoped UI machine for workshop express checkout (GH-512).
 *
 * It models the browser's temporal protocol — load Stripe, create a payment
 * intent, mount the Payment Element, confirm, then complete registration —
 * as mutually exclusive phases with stage-aware retry. Stripe objects stay
 * in the host component; do not persist a snapshot.
 *
 * Instantiate per component with `useMachine`; never at module scope.
 */

export type CheckoutFailureStage =
	| "loadingStripe"
	| "creatingPaymentIntent"
	| "preparingPaymentElement"
	| "confirmingPayment"
	| "completingRegistration";

export type CheckoutFailure = {
	message: string;
	stage: CheckoutFailureStage;
};

export type PaymentIntentCreated = {
	clientSecret: string;
	paymentIntentId: string;
};

export type WorkshopCheckoutInput = {
	workshopId: string;
	customerId?: string;
};

export type WorkshopCheckoutContext = {
	workshopId: string;
	customerId: string | undefined;
	clientSecret: string | undefined;
	paymentIntentId: string | undefined;
	failure: CheckoutFailure | undefined;
};

export type WorkshopCheckoutEvent =
	| { type: "CONFIRM" }
	| { type: "RETRY" }
	| { type: "CANCEL" };

export const workshopCheckoutMachineStates = [
	"loadingStripe",
	"creatingPaymentIntent",
	"preparingPaymentElement",
	"ready",
	"confirmingPayment",
	"completingRegistration",
	"succeeded",
	"failed",
	"cancelled",
] as const;

export type WorkshopCheckoutState =
	(typeof workshopCheckoutMachineStates)[number];

/** Implementations a host component provides through `workshopCheckoutMachine.provide`. */
export type WorkshopCheckoutImplementations = {
	loadStripe: () => Promise<void>;
	createPaymentIntent: (input: {
		workshopId: string;
		customerId: string | undefined;
	}) => Promise<PaymentIntentCreated>;
	preparePaymentElement: (input: { clientSecret: string }) => Promise<void>;
	confirmPayment: () => Promise<void>;
	completeRegistration: (input: {
		workshopId: string;
		paymentIntentId: string;
	}) => Promise<void>;
	notifySuccess: () => void;
	notifyCancel: () => void;
};

function messageOf(cause: unknown, fallback: string): string {
	return cause instanceof Error && cause.message ? cause.message : fallback;
}

function failureOf(
	cause: unknown,
	stage: CheckoutFailureStage,
	fallback: string,
): CheckoutFailure {
	return { message: messageOf(cause, fallback), stage };
}

export const workshopCheckoutMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as WorkshopCheckoutContext,
		events: {} as WorkshopCheckoutEvent,
		input: {} as WorkshopCheckoutInput,
	},
	actors: {
		loadStripe: fromPromise<void, void>(async () => {
			throw new Error("loadStripe must be provided by the host");
		}),
		createPaymentIntent: fromPromise<
			PaymentIntentCreated,
			{ workshopId: string; customerId: string | undefined }
		>(async () => {
			throw new Error("createPaymentIntent must be provided by the host");
		}),
		preparePaymentElement: fromPromise<void, { clientSecret: string }>(
			async () => {
				throw new Error("preparePaymentElement must be provided by the host");
			},
		),
		confirmPayment: fromPromise<void, void>(async () => {
			throw new Error("confirmPayment must be provided by the host");
		}),
		completeRegistration: fromPromise<
			void,
			{ workshopId: string; paymentIntentId: string }
		>(async () => {
			throw new Error("completeRegistration must be provided by the host");
		}),
	},
	actions: {
		notifySuccess: () => {},
		notifyCancel: () => {},
	},
	guards: {
		failedWhileLoadingStripe: ({ context }) =>
			context.failure?.stage === "loadingStripe",
		failedWhileCreatingPaymentIntent: ({ context }) =>
			context.failure?.stage === "creatingPaymentIntent",
		failedWhilePreparingPaymentElement: ({ context }) =>
			context.failure?.stage === "preparingPaymentElement",
		failedWhileConfirmingPayment: ({ context }) =>
			context.failure?.stage === "confirmingPayment",
		failedWhileCompletingRegistration: ({ context }) =>
			context.failure?.stage === "completingRegistration",
	},
}).createMachine({
	id: "workshopCheckout",
	context: ({ input }) => ({
		workshopId: input.workshopId,
		customerId: input.customerId,
		clientSecret: undefined,
		paymentIntentId: undefined,
		failure: undefined,
	}),
	initial: "loadingStripe",
	states: {
		loadingStripe: {
			invoke: {
				src: "loadStripe",
				onDone: { target: "creatingPaymentIntent" },
				onError: {
					target: "failed",
					actions: assign({
						failure: ({ event }) =>
							failureOf(
								event.error,
								"loadingStripe",
								"Failed to initialize Stripe",
							),
					}),
				},
			},
			on: { CANCEL: { target: "cancelled" } },
		},
		creatingPaymentIntent: {
			invoke: {
				src: "createPaymentIntent",
				input: ({ context }) => ({
					workshopId: context.workshopId,
					customerId: context.customerId,
				}),
				onDone: {
					target: "preparingPaymentElement",
					actions: assign({
						clientSecret: ({ event }) => event.output.clientSecret,
						paymentIntentId: ({ event }) => event.output.paymentIntentId,
					}),
				},
				onError: {
					target: "failed",
					actions: assign({
						failure: ({ event }) =>
							failureOf(
								event.error,
								"creatingPaymentIntent",
								"Failed to initialize payment",
							),
					}),
				},
			},
			on: { CANCEL: { target: "cancelled" } },
		},
		preparingPaymentElement: {
			invoke: {
				src: "preparePaymentElement",
				input: ({ context }) => ({
					clientSecret: context.clientSecret ?? "",
				}),
				onDone: { target: "ready" },
				onError: {
					target: "failed",
					actions: assign({
						failure: ({ event }) =>
							failureOf(
								event.error,
								"preparingPaymentElement",
								"Failed to initialize payment",
							),
					}),
				},
			},
			on: { CANCEL: { target: "cancelled" } },
		},
		ready: {
			on: {
				CONFIRM: { target: "confirmingPayment" },
				CANCEL: { target: "cancelled" },
			},
		},
		confirmingPayment: {
			invoke: {
				src: "confirmPayment",
				onDone: { target: "completingRegistration" },
				onError: {
					target: "failed",
					actions: assign({
						failure: ({ event }) =>
							failureOf(event.error, "confirmingPayment", "Payment failed"),
					}),
				},
			},
		},
		completingRegistration: {
			invoke: {
				src: "completeRegistration",
				input: ({ context }) => ({
					workshopId: context.workshopId,
					paymentIntentId: context.paymentIntentId ?? "",
				}),
				onDone: { target: "succeeded" },
				onError: {
					target: "failed",
					actions: assign({
						failure: ({ event }) =>
							failureOf(
								event.error,
								"completingRegistration",
								"Registration failed",
							),
					}),
				},
			},
		},
		succeeded: {
			entry: { type: "notifySuccess" },
		},
		failed: {
			on: {
				RETRY: [
					{
						guard: "failedWhileLoadingStripe",
						target: "loadingStripe",
						actions: assign({ failure: undefined }),
					},
					{
						guard: "failedWhileCreatingPaymentIntent",
						target: "creatingPaymentIntent",
						actions: assign({ failure: undefined }),
					},
					{
						guard: "failedWhilePreparingPaymentElement",
						target: "preparingPaymentElement",
						actions: assign({ failure: undefined }),
					},
					{
						guard: "failedWhileConfirmingPayment",
						target: "ready",
						actions: assign({ failure: undefined }),
					},
					{
						guard: "failedWhileCompletingRegistration",
						target: "completingRegistration",
						actions: assign({ failure: undefined }),
					},
				],
				CANCEL: { target: "cancelled" },
			},
		},
		cancelled: {
			entry: { type: "notifyCancel" },
		},
	},
});

export type WorkshopCheckoutPresentation = {
	/** Whether the primary button is disabled in this state. */
	confirmDisabled: boolean;
	/** Whether the primary button shows a spinner. */
	confirmBusy: boolean;
	/** Whether the Stripe Payment Element mount point should stay in the DOM. */
	showPaymentElement: boolean;
	/** Whether the failed-phase retry control is shown. */
	showRetry: boolean;
	/** Whether the failed-phase cancel control is shown. */
	showCancel: boolean;
	/** Accessible status line announced to the member, if any. */
	status: string | undefined;
};

/**
 * One intentional presentation per machine state. The record is exhaustive on
 * purpose (adding a state without deciding its UI is a type error). Failure
 * copy comes from `context.failure`, not from here.
 */
export const workshopCheckoutPresentation = {
	loadingStripe: {
		confirmDisabled: true,
		confirmBusy: false,
		showPaymentElement: false,
		showRetry: false,
		showCancel: false,
		status: "Initializing payment...",
	},
	creatingPaymentIntent: {
		confirmDisabled: true,
		confirmBusy: false,
		showPaymentElement: false,
		showRetry: false,
		showCancel: false,
		status: "Initializing payment...",
	},
	preparingPaymentElement: {
		confirmDisabled: true,
		confirmBusy: false,
		showPaymentElement: true,
		showRetry: false,
		showCancel: false,
		status: "Initializing payment...",
	},
	ready: {
		confirmDisabled: false,
		confirmBusy: false,
		showPaymentElement: true,
		showRetry: false,
		showCancel: false,
		status: undefined,
	},
	confirmingPayment: {
		confirmDisabled: true,
		confirmBusy: true,
		showPaymentElement: true,
		showRetry: false,
		showCancel: false,
		status: "Processing payment...",
	},
	completingRegistration: {
		confirmDisabled: true,
		confirmBusy: true,
		showPaymentElement: true,
		showRetry: false,
		showCancel: false,
		status: "Processing payment...",
	},
	succeeded: {
		confirmDisabled: true,
		confirmBusy: false,
		showPaymentElement: false,
		showRetry: false,
		showCancel: false,
		status: undefined,
	},
	failed: {
		confirmDisabled: true,
		confirmBusy: false,
		showPaymentElement: false,
		showRetry: true,
		showCancel: true,
		status: undefined,
	},
	cancelled: {
		confirmDisabled: true,
		confirmBusy: false,
		showPaymentElement: false,
		showRetry: false,
		showCancel: false,
		status: undefined,
	},
} satisfies Record<WorkshopCheckoutState, WorkshopCheckoutPresentation>;
