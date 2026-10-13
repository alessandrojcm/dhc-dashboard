import type { Page } from "@playwright/test";
import { stripeClient } from "./setupFunctions";

/**
 * ALE-398: stubs `https://js.stripe.com/**` so the Intake page's embedded
 * Checkout mounts a "Complete test payment" button that calls `onComplete`.
 * Phoenix still creates a real test-mode Checkout Session (the Seat Hold);
 * the returned cleanup expires every session the page opened that is still
 * open.
 */
export async function stubEmbeddedCheckout(page: Page) {
	const sessions = new Set<string>();
	await page.exposeFunction("recordIntakeCheckoutSession", (id: string) => {
		if (!id.startsWith("cs_test_")) throw new Error("Expected test session");
		sessions.add(id);
	});
	await page.route("https://js.stripe.com/**", (route) =>
		route.fulfill({
			contentType: "application/javascript",
			body: `window.Stripe = () => ({
				initEmbeddedCheckout: async ({ clientSecret, onComplete }) => {
					if (!/^cs_test_.*_secret_/.test(clientSecret)) throw new Error('Expected test session');
					await window.recordIntakeCheckoutSession(clientSecret.split('_secret_')[0]);
					let button;
					return {
						mount(container) {
							button = document.createElement('button');
							button.textContent = 'Complete test payment';
							button.onclick = onComplete;
							container.append(button);
						},
						destroy() { button?.remove(); }
					};
				}
			});`,
		}),
	);
	return async () => {
		for (const id of sessions) {
			const session = await stripeClient.checkout.sessions.retrieve(id);
			if (session.status === "open")
				await stripeClient.checkout.sessions.expire(id);
		}
	};
}
