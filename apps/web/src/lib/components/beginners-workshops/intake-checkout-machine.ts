import { fromPromise, setup, type SnapshotFrom } from "xstate";
import {
	embeddedCheckoutWidget,
	type EmbeddedCheckoutWidgetEvent,
	type EmbeddedCheckoutWidgetInput,
} from "#lib/stripe/embedded-checkout-widget.js";

/**
 * The Intake page's embedded Checkout widget (ALE-447): one actor per
 * `IntakeCheckout` instance, created with `useMachine` (never at module
 * scope). The page keys that component by client secret, so a different
 * Checkout Session is always a new actor.
 *
 * - `dormant`: `useMachine` also starts the actor during a server render, so
 *   nothing loads until the host sends `MOUNTED` from the mounted browser.
 * - `collecting` invokes the widget actor: the Stripe widget exists only
 *   while payment is being collected. `initFailed` retries by entering
 *   `collecting` again, which creates a fresh widget for the same session;
 *   it never starts another payment.
 * - Stripe's completion callback moves to `confirming`, which leaves
 *   `collecting` and so destroys the widget before Phoenix is asked for the
 *   outcome. `confirmFailed` retries only the confirmation: no transition
 *   leads from confirmation back to `collecting`, so a person who has paid
 *   is never shown payment collection again. Phoenix decides whether the
 *   place is paid; Stripe's browser callback never does.
 *
 * Failure copy is fixed: Stripe errors may contain credentials, so they are
 * never shown or logged.
 */

export type IntakeCheckoutInput = { clientSecret: string };

export type IntakeCheckoutEvent =
	| EmbeddedCheckoutWidgetEvent
	| { type: "MOUNTED" }
	| { type: "RETRY" };

export const intakeCheckoutMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as IntakeCheckoutInput,
		events: {} as IntakeCheckoutEvent,
		input: {} as IntakeCheckoutInput,
	},
	actors: {
		// The host provides both: the widget through `embeddedCheckoutWidget`
		// with its factory and container, and Phoenix's confirmation.
		widget: embeddedCheckoutWidget(
			async () => {
				throw new Error("widget must be provided by the host");
			},
			() => undefined,
		),
		confirm: fromPromise<void, void>(async () => {
			throw new Error("confirm must be provided by the host");
		}),
	},
}).createMachine({
	id: "intakeCheckout",
	context: ({ input }) => ({ clientSecret: input.clientSecret }),
	initial: "dormant",
	states: {
		dormant: { on: { MOUNTED: { target: "collecting" } } },
		collecting: {
			invoke: {
				src: "widget",
				input: ({ context }): EmbeddedCheckoutWidgetInput => ({
					clientSecret: context.clientSecret,
				}),
			},
			on: {
				"WIDGET.FAILED": { target: "initFailed" },
				"WIDGET.COMPLETED": { target: "confirming" },
			},
			initial: "loading",
			states: {
				loading: { on: { "WIDGET.MOUNTED": { target: "active" } } },
				active: {},
			},
		},
		initFailed: { on: { RETRY: { target: "collecting" } } },
		confirming: {
			invoke: {
				src: "confirm",
				onDone: { target: "confirmed" },
				onError: { target: "confirmFailed" },
			},
		},
		confirmFailed: { on: { RETRY: { target: "confirming" } } },
		// Phoenix answered; the page now shows its view.
		confirmed: {},
	},
});

export type IntakeCheckoutSnapshot = SnapshotFrom<typeof intakeCheckoutMachine>;

export type IntakeCheckoutPhase =
	| "loading"
	| "active"
	| "initFailed"
	| "confirming"
	| "confirmFailed"
	| "confirmed";

export type IntakeCheckoutView = {
	phase: IntakeCheckoutPhase;
	/** The status line while something is in flight, if any. */
	status: string | null;
	/** Fixed failure copy, if the phase failed. */
	failure: string | null;
	/** The retry control's label, if the phase offers one. */
	retry: string | null;
};

type Presentation = Omit<IntakeCheckoutView, "phase">;

/** One intentional presentation per phase; adding a phase is a type error here. */
const PRESENTATION = {
	loading: { status: "Loading secure payment…", failure: null, retry: null },
	active: { status: null, failure: null, retry: null },
	initFailed: {
		status: null,
		failure: "We couldn't load secure payment. Please try again.",
		retry: "Try again",
	},
	confirming: {
		status: "Confirming your payment…",
		failure: null,
		retry: null,
	},
	confirmFailed: {
		status: null,
		failure:
			"We couldn't check your payment yet. Check again — don't pay twice.",
		retry: "Check payment",
	},
	confirmed: { status: null, failure: null, retry: null },
} satisfies Record<IntakeCheckoutPhase, Presentation>;

function phaseOf(snapshot: IntakeCheckoutSnapshot): IntakeCheckoutPhase {
	if (snapshot.matches({ collecting: "active" })) return "active";
	if (snapshot.matches("initFailed")) return "initFailed";
	if (snapshot.matches("confirming")) return "confirming";
	if (snapshot.matches("confirmFailed")) return "confirmFailed";
	if (snapshot.matches("confirmed")) return "confirmed";
	// `dormant` (server render, before mount) and `collecting.loading`.
	return "loading";
}

/** The closed view of a widget snapshot: what `IntakeCheckout` renders. */
export function intakeCheckoutView(
	snapshot: IntakeCheckoutSnapshot,
): IntakeCheckoutView {
	const phase = phaseOf(snapshot);
	return { phase, ...PRESENTATION[phase] };
}
