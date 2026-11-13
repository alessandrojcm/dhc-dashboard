import { setup, type SnapshotFrom } from "xstate";
import {
	embeddedCheckoutWidget,
	type EmbeddedCheckoutWidgetEvent,
	type EmbeddedCheckoutWidgetInput,
} from "#lib/stripe/embedded-checkout-widget.js";

/**
 * Public regular-Workshop registration's embedded Checkout (ALE-447): one
 * actor per `WorkshopRegistrationCheckout` instance, created with
 * `useMachine` (never at module scope). The page keys that component by
 * Checkout Session id, so a different session is always a new actor.
 *
 * The page's load has already created the Checkout Session; this machine
 * owns only the widget's lifecycle.
 *
 * - `dormant`: `useMachine` also starts the actor during a server render, so
 *   nothing loads until the host sends `MOUNTED` from the mounted browser.
 *   Without a Stripe key or a session the machine settles at once in a
 *   terminal unavailable state that no retry can fix (and never loads
 *   Stripe).
 * - `collecting` invokes the widget actor: the Stripe widget exists only
 *   while that state is active, and leaving it or stopping the actor
 *   destroys it. `initFailed` retries by entering `collecting` again, which
 *   creates a fresh widget for the same session.
 * - Completion is Stripe's: the session redirects to the confirmation page
 *   (`redirect_on_completion` defaults to `always`), so there is no
 *   confirmation phase and a completion event changes nothing here.
 *
 * Failure copy is fixed: Stripe errors may contain credentials, so they are
 * never shown or logged.
 *
 * This is deliberately not the Beginners' Workshop Intake machine: the two
 * domains share only the widget adapter.
 */

export type WorkshopRegistrationCheckoutInput = {
	clientSecret: string | null | undefined;
	stripeConfigured: boolean;
};

export type WorkshopRegistrationCheckoutContext = {
	/** Empty when the session is missing; the machine is then unavailable. */
	clientSecret: string;
	stripeConfigured: boolean;
};

export type WorkshopRegistrationCheckoutEvent =
	| EmbeddedCheckoutWidgetEvent
	| { type: "MOUNTED" }
	| { type: "RETRY" };

export const workshopRegistrationCheckoutMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as WorkshopRegistrationCheckoutContext,
		events: {} as WorkshopRegistrationCheckoutEvent,
		input: {} as WorkshopRegistrationCheckoutInput,
	},
	actors: {
		// The host provides it through `embeddedCheckoutWidget` with its own
		// factory and container.
		widget: embeddedCheckoutWidget(
			async () => {
				throw new Error("widget must be provided by the host");
			},
			() => undefined,
		),
	},
	guards: {
		stripeMissing: ({ context }) => !context.stripeConfigured,
		sessionMissing: ({ context }) => !context.clientSecret,
	},
}).createMachine({
	id: "workshopRegistrationCheckout",
	context: ({ input }) => ({
		clientSecret: input.clientSecret ?? "",
		stripeConfigured: input.stripeConfigured,
	}),
	initial: "dormant",
	states: {
		dormant: {
			always: [
				{ guard: "stripeMissing", target: "paymentUnavailable" },
				{ guard: "sessionMissing", target: "sessionMissing" },
			],
			on: { MOUNTED: { target: "collecting" } },
		},
		collecting: {
			invoke: {
				src: "widget",
				input: ({ context }): EmbeddedCheckoutWidgetInput => ({
					clientSecret: context.clientSecret,
				}),
			},
			on: { "WIDGET.FAILED": { target: "initFailed" } },
			initial: "loading",
			states: {
				loading: { on: { "WIDGET.MOUNTED": { target: "active" } } },
				active: {},
			},
		},
		initFailed: { on: { RETRY: { target: "collecting" } } },
		// Terminal for the user, but not `final`: the host still sends
		// `MOUNTED`, which a done actor would warn about.
		paymentUnavailable: {},
		sessionMissing: {},
	},
});

export type WorkshopRegistrationCheckoutSnapshot = SnapshotFrom<
	typeof workshopRegistrationCheckoutMachine
>;

export type WorkshopRegistrationCheckoutPhase =
	| "loading"
	| "active"
	| "initFailed"
	| "paymentUnavailable"
	| "sessionMissing";

export type WorkshopRegistrationCheckoutView = {
	phase: WorkshopRegistrationCheckoutPhase;
	/** The loading line while the widget initializes, if any. */
	status: string | null;
	/** Fixed registration-error copy, if the phase failed. */
	failure: string | null;
	/** The retry control's label, if the phase offers one. */
	retry: string | null;
};

type Presentation = Omit<WorkshopRegistrationCheckoutView, "phase">;

/** One intentional presentation per phase; adding a phase is a type error here. */
const PRESENTATION = {
	loading: { status: "Loading payment form...", failure: null, retry: null },
	active: { status: null, failure: null, retry: null },
	initFailed: {
		status: null,
		failure: "Failed to initialize checkout. Please try again.",
		retry: "Try again",
	},
	paymentUnavailable: {
		status: null,
		failure: "Payment is currently unavailable. Please try again later.",
		retry: null,
	},
	sessionMissing: {
		status: null,
		failure: "Failed to initialize checkout. Please refresh and try again.",
		retry: null,
	},
} satisfies Record<WorkshopRegistrationCheckoutPhase, Presentation>;

function phaseOf(
	snapshot: WorkshopRegistrationCheckoutSnapshot,
): WorkshopRegistrationCheckoutPhase {
	if (snapshot.matches({ collecting: "active" })) return "active";
	if (snapshot.matches("initFailed")) return "initFailed";
	if (snapshot.matches("paymentUnavailable")) return "paymentUnavailable";
	if (snapshot.matches("sessionMissing")) return "sessionMissing";
	// `dormant` (server render, before mount) and `collecting.loading`.
	return "loading";
}

/** The closed view of a snapshot: what `WorkshopRegistrationCheckout` renders. */
export function workshopRegistrationCheckoutView(
	snapshot: WorkshopRegistrationCheckoutSnapshot,
): WorkshopRegistrationCheckoutView {
	const phase = phaseOf(snapshot);
	return { phase, ...PRESENTATION[phase] };
}
