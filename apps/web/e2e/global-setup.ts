import { resetE2EState } from "./e2eApi";

async function globalSetup() {
	const stripeSecretKey = process.env.STRIPE_SECRET_KEY;
	if (!stripeSecretKey?.startsWith("sk_test_")) {
		throw new Error(
			"Real-Stripe E2E requires STRIPE_SECRET_KEY to be a non-empty test-mode key (sk_test_...).",
		);
	}

	await resetE2EState();
}

export default globalSetup;
