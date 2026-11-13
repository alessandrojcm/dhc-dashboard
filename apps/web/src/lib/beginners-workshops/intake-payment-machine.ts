/**
 * ALE-447: the Intake page's payment orchestration, one actor per Intake
 * page instance, created with `useMachine` (never at module scope). The
 * route keys the page by token, so another link is always a new actor.
 *
 * Phoenix's safe view stays authoritative: the host sends every new view as
 * `PAGE`, and the machine only follows its `action` and `state`; it never
 * infers a payment outcome itself.
 *
 * `useMachine` also starts the actor during a server render, so the machine
 * stays `dormant` until the host sends `MOUNTED` from the mounted browser:
 * a server render or a prefetch of the page's GET never reserves a place
 * and never arms the refresh timer.
 *
 * Once live, two independent regions run side by side:
 *
 * - `start`: the payment start. Opening the link starts payment
 *   automatically, once per instance, as the browser POST that takes the
 *   Seat Hold; Phoenix resumes a live hold's session rather than creating
 *   another. A refusal keeps Phoenix's detail (an unexpected failure, fixed
 *   copy) and offers a manual retry. When Phoenix's view leaves payment, the
 *   session is dropped (`spent`): if the view later asks for payment again,
 *   the person starts it by hand, so the page never POSTs twice on its own
 *   and never remounts a session it already handed to the widget. The start
 *   is not tied to the view, so a view that changes while the POST is in
 *   flight (the form's own reload) never cancels it.
 * - `view`: which of Phoenix's actions the page offers. `awaitingPayment`
 *   (`payment_in_progress`) asks Phoenix again `refreshMs` after every new
 *   view, until it reports another state. `confirmPlace` is the Carried Fee
 *   holder's "Confirm my place"; its remote form is the transport and owns
 *   its own pending and result.
 *
 * The embedded widget's own machine (`intake-checkout-machine.ts`) owns
 * collection and confirmation once `start` hands it a session.
 */
import type { BeginnersIntakePage } from "@dhc/api-client";
import { assign, fromPromise, setup, type SnapshotFrom } from "xstate";
import {
	confirmsWithCarriedFee,
	intakeActionLabel,
	startsCheckout,
} from "#lib/beginners-workshops/intake-page.js";

/** What the start-payment POST answers; `undefined` while it redirects away. */
export type IntakePaymentStart =
	| { ok: true; clientSecret: string; sessionId: string }
	| { ok: false; error: string }
	| undefined;

export type IntakeCheckoutSession = { clientSecret: string; sessionId: string };

export type IntakePaymentInput = {
	page: BeginnersIntakePage;
	refreshMs: number;
};

export type IntakePaymentContext = IntakePaymentInput & {
	/** The session the start opened, while Phoenix's view still pays. */
	session: IntakeCheckoutSession | null;
	/** Why the last start did not open payment, worded for the person. */
	refusal: string | null;
};

export type IntakePaymentEvent =
	| { type: "MOUNTED" }
	| { type: "PAGE"; page: BeginnersIntakePage }
	| { type: "RETRY" }
	| { type: "REFRESH" };

/** Fixed copy for a start that failed without Phoenix's detail. */
export const START_FAILED =
	"Payment is unavailable right now. Please try again shortly.";

/** Which of Phoenix's actions a view offers. */
export type IntakeRoute =
	| "pay"
	| "confirmPlace"
	| "awaitingPayment"
	| "settled";

export function intakeRoute(page: BeginnersIntakePage): IntakeRoute {
	if (startsCheckout(page)) return "pay";
	if (confirmsWithCarriedFee(page)) return "confirmPlace";
	if (page.state === "payment_in_progress") return "awaitingPayment";
	return "settled";
}

export const intakePaymentMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as IntakePaymentContext,
		events: {} as IntakePaymentEvent,
		input: {} as IntakePaymentInput,
	},
	actors: {
		startPayment: fromPromise<IntakePaymentStart, void>(async () => {
			throw new Error("startPayment must be provided by the host");
		}),
	},
	actions: {
		/** Ask Phoenix for its view again (the host reloads the page's load). */
		refresh: () => {},
		adoptPage: assign({
			page: ({ context, event }) =>
				event.type === "PAGE" ? event.page : context.page,
		}),
	},
	guards: {
		newPage: ({ context, event }) =>
			event.type === "PAGE" && event.page !== context.page,
		pays: ({ context }) => intakeRoute(context.page) === "pay",
		notPaying: ({ context }) => intakeRoute(context.page) !== "pay",
		confirms: ({ context }) => intakeRoute(context.page) === "confirmPlace",
		paymentInProgress: ({ context }) =>
			intakeRoute(context.page) === "awaitingPayment",
	},
	delays: {
		refreshDelay: ({ context }) => context.refreshMs,
	},
}).createMachine({
	id: "intakePayment",
	context: ({ input }) => ({ ...input, session: null, refusal: null }),
	initial: "dormant",
	states: {
		dormant: {
			on: {
				MOUNTED: { target: "live" },
				PAGE: { guard: "newPage", actions: "adoptPage" },
			},
		},
		live: {
			type: "parallel",
			states: {
				start: {
					initial: "waiting",
					states: {
						// The one automatic start: taken the first time the live
						// page's view asks for payment, and never again.
						waiting: { always: { guard: "pays", target: "starting" } },
						starting: {
							invoke: {
								src: "startPayment",
								onDone: [
									{
										guard: ({ event }) => event.output?.ok === true,
										target: "open",
										actions: assign({
											session: ({ event }) =>
												event.output?.ok
													? {
															clientSecret: event.output.clientSecret,
															sessionId: event.output.sessionId,
														}
													: null,
											refusal: null,
										}),
									},
									{
										guard: ({ event }) => event.output?.ok === false,
										target: "refused",
										actions: assign({
											refusal: ({ event }) =>
												event.output?.ok === false ? event.output.error : null,
										}),
									},
									// A hold created before the embedded migration redirects
									// to hosted Checkout; the page is leaving.
									{ target: "redirecting" },
								],
								onError: {
									target: "refused",
									actions: assign({ refusal: START_FAILED }),
								},
							},
						},
						open: {
							// A view that still pays (the reload right after the
							// POST, a live hold) keeps the session and the widget.
							always: { guard: "notPaying", target: "spent" },
						},
						refused: {
							on: { RETRY: { guard: "pays", target: "starting" } },
						},
						spent: {
							entry: assign({ session: null }),
							on: { RETRY: { guard: "pays", target: "starting" } },
						},
						redirecting: {},
					},
				},
				view: {
					initial: "routing",
					on: {
						PAGE: {
							guard: "newPage",
							target: ".routing",
							actions: "adoptPage",
						},
					},
					states: {
						routing: {
							always: [
								{ guard: "pays", target: "pay" },
								{ guard: "confirms", target: "confirmPlace" },
								{ guard: "paymentInProgress", target: "awaitingPayment" },
								{ target: "settled" },
							],
						},
						pay: {},
						confirmPlace: {},
						awaitingPayment: {
							on: { REFRESH: { actions: "refresh" } },
							after: { refreshDelay: { actions: "refresh" } },
						},
						settled: {
							on: { REFRESH: { actions: "refresh" } },
						},
					},
				},
			},
		},
	},
});

export type IntakePaymentSnapshot = SnapshotFrom<typeof intakePaymentMachine>;

/** What the page's footer offers for a snapshot. */
export type IntakePaymentFooter =
	/** Payment is starting (or redirecting): a status line, nothing to press. */
	| { kind: "loading" }
	/** The embedded widget, for the session the start opened. */
	| { kind: "checkout"; session: IntakeCheckoutSession }
	/** A manual start; `busy` while the retry it sent is in flight. */
	| { kind: "retry"; label: string; busy: boolean }
	/** The Carried Fee holder's "Confirm my place" remote form. */
	| { kind: "confirm" }
	/** Ask Phoenix again; `inProgress` while it refreshes on its own. */
	| { kind: "refresh"; inProgress: boolean };

export type IntakePaymentView = {
	footer: IntakePaymentFooter;
	/** The payment start's refusal; the confirm form words its own. */
	refusal: string | null;
};

const RETRY = "Try again";

function payFooter(snapshot: IntakePaymentSnapshot): IntakePaymentFooter {
	const { session, refusal, page } = snapshot.context;
	if (snapshot.matches({ live: { start: "open" } }) && session)
		return { kind: "checkout", session };
	if (snapshot.matches({ live: { start: "refused" } }))
		return { kind: "retry", label: RETRY, busy: false };
	if (snapshot.matches({ live: { start: "spent" } }))
		return {
			kind: "retry",
			label: intakeActionLabel(page) ?? RETRY,
			busy: false,
		};
	// A retry after a refusal keeps the refusal and its button on screen
	// while it runs, like the first attempt's form did.
	if (snapshot.matches({ live: { start: "starting" } }) && refusal)
		return { kind: "retry", label: RETRY, busy: true };
	// `dormant`, the first start, and a hosted redirect.
	return { kind: "loading" };
}

/** The closed view of a page snapshot: what `intake-page.svelte` renders. */
export function intakePaymentView(
	snapshot: IntakePaymentSnapshot,
): IntakePaymentView {
	const route = intakeRoute(snapshot.context.page);
	const refusal = route === "confirmPlace" ? null : snapshot.context.refusal;
	switch (route) {
		case "pay":
			return { footer: payFooter(snapshot), refusal };
		case "confirmPlace":
			return { footer: { kind: "confirm" }, refusal };
		case "awaitingPayment":
			return { footer: { kind: "refresh", inProgress: true }, refusal };
		case "settled":
			return { footer: { kind: "refresh", inProgress: false }, refusal };
	}
}
