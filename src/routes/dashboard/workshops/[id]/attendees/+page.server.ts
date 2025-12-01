import { error } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import {
	createWorkshopService,
	createRegistrationService,
	createRefundService
} from '$lib/server/services/workshops';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals, platform }) => {
	const session = await authorize(locals, WORKSHOP_ROLES);

	const workshopId = params.id;

	const workshopService = createWorkshopService(platform!, session);
	const registrationService = createRegistrationService(platform!, session);
	const refundService = createRefundService(platform!, session);

	// Run all queries in parallel for better performance
	const [workshop, attendees, refunds] = await Promise.all([
		// Verify the workshop exists and get refund policy
		workshopService.findById(workshopId),

		// Load attendees with proper joins
		registrationService.getWorkshopAttendees(workshopId),

		// Load refunds with proper joins
		refundService.getWorkshopRefunds(workshopId)
	]);

	if (!workshop) {
		error(404, {
			message: 'Workshop not found'
		});
	}

	return {
		workshop,
		attendees,
		refunds
	};
};
