import type {
	StripeEmbeddedCheckout,
	StripeEmbeddedCheckoutOptions,
} from "@stripe/stripe-js";
import { fromCallback, type EventObject } from "xstate";

/**
 * Stripe's embedded Checkout widget as an XState callback actor (ALE-447).
 *
 * The actor's lifetime is the widget's: it creates the widget when it
 * starts, mounts it, reports what happened, and destroys it when it stops.
 * A machine that invokes it from the state where payment is collected
 * therefore destroys the widget by leaving that state. A widget that
 * resolves after the actor stopped is destroyed instead of mounted, and
 * Stripe callbacks that arrive after the stop are dropped.
 *
 * This is an SDK adapter only, and it is domain-neutral: each domain keeps
 * its own machine and decides what a failure or a completion means. Do not
 * grow it into a checkout flow.
 */

export type EmbeddedCheckoutWidget = Pick<
	StripeEmbeddedCheckout,
	"mount" | "destroy"
>;

/** Creates the widget for one Checkout Session; injected so tests need no Stripe. */
export type EmbeddedCheckoutFactory = (
	options: StripeEmbeddedCheckoutOptions,
) => Promise<EmbeddedCheckoutWidget>;

/**
 * What the widget actor reports to the machine that invoked it. A failure
 * carries no error: Stripe errors may contain credentials, so they never
 * leave the adapter.
 */
export type EmbeddedCheckoutWidgetEvent =
	| { type: "WIDGET.MOUNTED" }
	| { type: "WIDGET.COMPLETED" }
	| { type: "WIDGET.FAILED" };

export type EmbeddedCheckoutWidgetInput = { clientSecret: string };

/**
 * Builds the widget actor from a factory and the element to mount into.
 * `container` is read once the widget resolves, so the host's element
 * binding may settle after the actor starts.
 */
export function embeddedCheckoutWidget(
	create: EmbeddedCheckoutFactory,
	container: () => HTMLElement | undefined,
) {
	return fromCallback<EventObject, EmbeddedCheckoutWidgetInput>(
		({ input, sendBack }) => {
			let stopped = false;
			let widget: EmbeddedCheckoutWidget | undefined;
			const report = (event: EmbeddedCheckoutWidgetEvent) => {
				if (!stopped) sendBack(event);
			};

			void (async () => {
				try {
					const created = await create({
						clientSecret: input.clientSecret,
						onComplete: () => report({ type: "WIDGET.COMPLETED" }),
					});
					if (stopped) {
						created.destroy();
						return;
					}
					widget = created;
					const element = container();
					if (!element) throw new Error("Checkout container is missing");
					created.mount(element);
					report({ type: "WIDGET.MOUNTED" });
				} catch {
					// The invoking machine leaves its collecting state on failure,
					// which stops this actor and destroys any widget created first.
					report({ type: "WIDGET.FAILED" });
				}
			})();

			return () => {
				stopped = true;
				widget?.destroy();
				widget = undefined;
			};
		},
	);
}
