/**
 * ALE-381: the person's Intake page. A thin adapter: one Phoenix read (or,
 * on the Stripe success return, the completion that retrieves the session
 * server-side) and the safe view Phoenix answers. The token is the only
 * credential, so the page never sends a referrer and is never cached.
 */
import { error } from "@sveltejs/kit";
import {
	beginnersWorkshopIntakeReturnFromCheckout,
	beginnersWorkshopIntakeShow,
	type BeginnersIntakePage,
} from "@dhc/api-client";
import { INACTIVE_PAGE } from "#lib/beginners-workshops/intake-page.js";
import { apiClientOptions } from "#lib/server/api-client.js";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({
	params,
	url,
	cookies,
	setHeaders,
}) => {
	setHeaders({ "referrer-policy": "no-referrer", "cache-control": "no-store" });

	const options = {
		...apiClientOptions(cookies),
		path: { token: params.token },
	};
	const sessionId = url.searchParams.get("session_id");

	const response = sessionId
		? await beginnersWorkshopIntakeReturnFromCheckout({
				...options,
				body: { sessionId },
			})
		: await beginnersWorkshopIntakeShow(options);

	if (response.data) return { page: response.data.data, token: params.token };
	if (response.response?.status === 404) {
		return {
			page: INACTIVE_PAGE satisfies BeginnersIntakePage,
			token: params.token,
		};
	}

	error(
		503,
		"We couldn't load your place right now. Please try again shortly.",
	);
};
