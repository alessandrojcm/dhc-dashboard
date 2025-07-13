import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { createWorkshop } from '$lib/server/workshops';
import { CreateWorkshopSchema } from '$lib/schemas/workshops';
import { safeParse } from 'valibot';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';
import dayjs from 'dayjs';

export const POST: RequestHandler = async ({ request, locals, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const body = await request.json();
		const result = safeParse(CreateWorkshopSchema, body);

		if (!result.success) {
			return json(
				{ success: false, error: 'Invalid data', issues: result.issues },
				{ status: 400 }
			);
		}

		// Transform form data to database format
		const workshopDate = dayjs(result.output.workshop_date);
		const [hours, minutes] = result.output.workshop_time.split(':').map(Number);
		const startDateTime = workshopDate.hour(hours).minute(minutes).toISOString();

		// Convert euro prices to cents
		const memberPriceCents = Math.round((result.output.price_member || 0) * 100);
		const nonMemberPriceCents =
			result.output.is_public && result.output.price_non_member
				? Math.round(result.output.price_non_member * 100)
				: memberPriceCents;

		const workshopData = {
			title: result.output.title,
			description: result.output.description,
			location: result.output.location,
			start_date: startDateTime,
			max_capacity: result.output.max_capacity,
			price_member: memberPriceCents,
			price_non_member: nonMemberPriceCents,
			is_public: result.output.is_public || false,
			refund_days: result.output.refund_deadline_days
		};

		const workshop = await createWorkshop(workshopData, session, platform!);

		return json({ success: true, workshop });
	} catch (error) {
		Sentry.captureException(error);
		console.error('Create workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};
