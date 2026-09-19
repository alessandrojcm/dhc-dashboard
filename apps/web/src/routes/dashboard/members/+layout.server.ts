import { membersInsuranceForm } from "@dhc/api-client";
import { error } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import { authorizationFor } from "$lib/server/authorization";
import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({ locals, cookies }) => {
	const { session } = await locals.safeGetSession();
	// This layout also wraps a member's own profile, so it only requires a
	// session; `[memberId]/+page.server.ts` applies the contextual rule.
	const access = authorizationFor(session);
	if (!session) error(401, { message: "Unauthorized" });
	const canEditSettings = access.can("members.settings.edit");
	// ALE-252: mirrors the Phoenix `:membership_minting_api` pipeline. The
	// directory table uses it to show the Reactivate action for inactive rows.
	const canReactivate = access.can("membership.reactivate");

	if (!canEditSettings) {
		return { canEditSettings, canReactivate, membersInsuranceFormLink: "" };
	}

	const insuranceFormResponse = await membersInsuranceForm({
		...apiClientOptions(cookies),
		throwOnError: true,
	});

	return {
		canEditSettings,
		canReactivate,
		membersInsuranceFormLink: insuranceFormResponse.data.data.link ?? "",
	};
};
