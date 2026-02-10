import { authorize } from "$lib/server/auth";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import { createWorkshopService } from "$lib/server/services/workshops";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, params, platform }) => {
	const session = await authorize(locals, WORKSHOP_ROLES);

	const workshopService = createWorkshopService(platform!, session);

	// Fetch workshop data
	const workshop = await workshopService.findById(params.id);

	// Check if workshop can be edited
	const workshopEditable = await workshopService.canEdit(params.id);

	// Check if pricing can be edited
	const pricingEditable = await workshopService.canEditPricing(params.id);

	// Transform workshop data to form format
	const initialData = {
		title: workshop.title,
		description: workshop.description || "",
		location: workshop.location,
		workshop_date: new Date(workshop.start_date),
		workshop_end_date: new Date(workshop.end_date),
		max_capacity: workshop.max_capacity,
		price_member: workshop.price_member / 100, // Convert from cents to euros
		price_non_member: workshop.price_non_member
			? workshop.price_non_member / 100
			: undefined,
		is_public: workshop.is_public || false,
		refund_deadline_days: workshop.refund_days || null,
	};

	return {
		workshop,
		initialData,
		workshopEditable,
		priceEditingDisabled: !pricingEditable,
	};
};
