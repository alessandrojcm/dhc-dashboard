import { error } from "@sveltejs/kit";
import { workshopsShow } from "@dhc/api-client";
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, params }) => {
	const session = await authorize(locals, WORKSHOP_ROLES);
	const {
		data,
		error: apiError,
		response,
	} = await workshopsShow({
		...apiClientOptions(session),
		path: { workshopId: params.id },
	});

	if (apiError) {
		if (response?.status === 404) {
			error(404, "Workshop not found");
		}
		if (response?.status === 403) {
			error(403, "Insufficient role");
		}
		error(503, "Unable to load workshop");
	}

	const workshop = data.data.workshop;
	const workshopEditable = workshop.status === "planned";
	const pricingEditable =
		workshopEditable ||
		(workshop.pendingRegistrationCount === 0 &&
			workshop.confirmedRegistrationCount === 0);

	// Transform workshop data to form format
	const initialData = {
		title: workshop.title,
		description: workshop.description || "",
		location: workshop.location ?? "",
		workshop_date: new Date(workshop.startDate),
		workshop_end_date: new Date(workshop.endDate),
		max_capacity: workshop.maxCapacity ?? 1,
		price_member: (workshop.priceMember ?? 0) / 100,
		price_non_member: workshop.priceNonMember
			? workshop.priceNonMember / 100
			: undefined,
		is_public: workshop.isPublic,
		refund_deadline_days: workshop.refundDays,
	};

	return {
		workshop,
		initialData,
		workshopEditable,
		priceEditingDisabled: !pricingEditable,
	};
};
