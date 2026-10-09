/**
 * ALE-381: the Intake page's Pay action. Phoenix takes the Seat Hold and
 * creates (or reuses) the Stripe Checkout Session; the person is sent there
 * with an external redirect. A refusal (`full`, `after_cutoff`, …) answers
 * its detail, and the page reloads Phoenix's view.
 */
import { form, getRequestEvent } from "$app/server";
import { redirect } from "@sveltejs/kit";
import { beginnersWorkshopIntakeStartPayment } from "@dhc/api-client";
import { apiProblem } from "#lib/api-error.js";
import { intakePaymentSchema } from "#lib/schemas/beginnersIntake.js";
import { apiClientOptions } from "#lib/server/api-client.js";

export const startIntakePayment = form(
	intakePaymentSchema,
	async ({ token }) => {
		const response = await beginnersWorkshopIntakeStartPayment({
			...apiClientOptions(getRequestEvent().cookies),
			path: { token },
		});

		if (response.data) {
			redirect(303, response.data.data.checkoutUrl, { external: true });
		}

		return {
			ok: false as const,
			error:
				apiProblem(response.error)?.detail ??
				"Payment is unavailable right now. Please try again shortly.",
		};
	},
);
