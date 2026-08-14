import { authVerifyRecoveryMagicLink } from "@dhc/api-client";
import * as Sentry from "@sentry/sveltekit";
import { redirect } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import type { PageServerLoad } from "./$types";

const recoveryPath = "/auth/identity-recovery";

const statusMessages = {
	"destination-proof-received":
		"Your identity proof was recorded. The recovery still requires two administrator approvals before it can be completed.",
	"discord-proof-received":
		"Your Discord proof was recorded. The recovery still requires destination proof and two administrator approvals before it can be completed.",
} as const;

export const load: PageServerLoad = async ({ url, cookies }) => {
	const caseReference = url.searchParams.get("caseReference");
	const token = url.searchParams.get("token");

	if (caseReference && token) {
		let proofReceived = false;

		try {
			const { error, response } = await authVerifyRecoveryMagicLink({
				...apiClientOptions(cookies),
				path: { caseReference },
				body: { token },
			});

			proofReceived = !error && response?.ok === true;
		} catch (error) {
			Sentry.captureException(error);
			proofReceived = false;
		}

		const params = new URLSearchParams({
			caseReference,
			status: proofReceived ? "destination-proof-received" : "failed",
		});

		redirect(303, `${recoveryPath}?${params}`);
	}

	const status = url.searchParams.get("status");
	const message =
		status && Object.hasOwn(statusMessages, status)
			? statusMessages[status as keyof typeof statusMessages]
			: undefined;

	return {
		caseReference,
		success: Boolean(message),
		message:
			message ??
			"This recovery proof is invalid, expired, or has already been used.",
	};
};
