import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { updateWorkshop, deleteWorkshop } from '$lib/server/workshops';
import { UpdateWorkshopSchema } from '$lib/schemas/workshops';
import { safeParse } from 'valibot';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';
import dayjs from 'dayjs';

export const PUT: RequestHandler = async ({ request, locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const body = await request.json();
		const result = safeParse(UpdateWorkshopSchema, body);

		if (!result.success) {
			return json(
				{ success: false, error: 'Invalid data', issues: result.issues },
				{ status: 400 }
			);
		}

		// Transform form data to database format (only for fields that are present)
		const updateData: any = {};

		// Copy non-transformed fields
		if (result.output.title !== undefined) updateData.title = result.output.title;
		if (result.output.description !== undefined) updateData.description = result.output.description;
		if (result.output.location !== undefined) updateData.location = result.output.location;
		if (result.output.max_capacity !== undefined)
			updateData.max_capacity = result.output.max_capacity;
		if (result.output.is_public !== undefined) updateData.is_public = result.output.is_public;

		// Transform workshop_date + workshop_time to start_date if both are present
		if (result.output.workshop_date !== undefined && result.output.workshop_time !== undefined) {
			const workshopDate = dayjs(result.output.workshop_date);
			const [hours, minutes] = result.output.workshop_time.split(':').map(Number);
			updateData.start_date = workshopDate.hour(hours).minute(minutes).toISOString();
		}

		// Transform euro prices to cents if present
		if (result.output.price_member !== undefined) {
			updateData.price_member = Math.round(result.output.price_member * 100);
		}
		if (result.output.price_non_member !== undefined) {
			updateData.price_non_member = Math.round(result.output.price_non_member * 100);
		}

		// Transform refund_deadline_days to refund_days if present
		if (result.output.refund_deadline_days !== undefined) {
			updateData.refund_days = result.output.refund_deadline_days;
		}

		const workshop = await updateWorkshop(params.id!, updateData, session, platform!);

		return json({ success: true, workshop });
	} catch (error) {
		Sentry.captureException(error);
		console.error('Update workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};

export const DELETE: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		await deleteWorkshop(params.id!, session, platform!);

		return json({ success: true });
	} catch (error) {
		Sentry.captureException(error);
		console.error('Delete workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};
