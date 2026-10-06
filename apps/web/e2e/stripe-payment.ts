import type { Page } from "@playwright/test";

/**
 * The Stripe Payment Element, addressed by the accessible title Stripe gives
 * its input iframe rather than Stripe's private wrapper class.
 */
export function stripePaymentFrameElement(page: Page) {
	return page.getByTitle("Secure payment input frame");
}

export function stripePaymentFrame(page: Page) {
	return stripePaymentFrameElement(page).contentFrame();
}

/**
 * The signup submit button. It is enabled only once the payment step has
 * decided its mode and, for a paid signup, mounted the Payment Element, so
 * waiting for it to be enabled is waiting for the form to be ready.
 */
export function signupSubmitButton(page: Page) {
	return page.getByRole("button", { name: /^(Sign up|Complete signup)$/ });
}
