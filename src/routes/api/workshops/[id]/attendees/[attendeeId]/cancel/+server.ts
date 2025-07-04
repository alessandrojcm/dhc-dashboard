import { json, error } from '@sveltejs/kit';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import { moveCancelledAttendeeToWaitlist } from '$lib/server/kyselyRPCFunctions';
import type { RequestHandler } from './$types';
import * as v from 'valibot';
import * as Sentry from '@sentry/sveltekit';
import { getRolesFromSession } from '$lib/server/roles';

const cancelAttendeeSchema = v.object({
	reason: v.optional(v.string()),
	moveToWaitlist: v.optional(v.boolean(), false),
	requestRefund: v.optional(v.boolean(), false)
});

export const POST: RequestHandler = async ({ params, request, locals, platform }) => {
	// Check authentication
	const { session } = await locals.safeGetSession();
	if (!session) throw error(401, 'Not authenticated');

	// Role check - same roles allowed for workshop management
	const roles = getRolesFromSession(session) as Set<string>;
	const allowed = new Set(['admin', 'president', 'beginners_coordinator']);
	const intersection = new Set([...roles].filter((role) => allowed.has(role)));
	if (intersection.size === 0) {
		throw error(403, 'Insufficient permissions');
	}

	const workshopId = params.id;
	const attendeeId = params.attendeeId;

	if (!workshopId || !attendeeId) {
		throw error(400, 'Workshop ID and Attendee ID required');
	}

	const db = getKyselyClient(platform?.env.HYPERDRIVE);
	if (!db) {
		throw error(500, 'Database connection failed');
	}

	let body: unknown;
	try {
		body = await request.json();
	} catch (err) {
		Sentry.captureException(err);
		throw error(400, 'Invalid JSON');
	}

	const parsed = v.safeParse(cancelAttendeeSchema, body);
	if (!parsed.success) {
		Sentry.captureException(parsed.issues);
		throw error(400, 'Validation failed: ' + JSON.stringify(parsed.issues));
	}

	const { reason, moveToWaitlist, requestRefund } = parsed.output;
	try {
		const result = await executeWithRLS(db, { claims: session }, async (trx) => {
			// First, verify the attendee exists and get their details
			const attendee = await trx
				.selectFrom('workshop_attendees')
				.leftJoin('user_profiles', 'workshop_attendees.user_profile_id', 'user_profiles.id')
				.select([
					'workshop_attendees.id',
					'workshop_attendees.status',
					'workshop_attendees.paid_at',
					'workshop_attendees.user_profile_id',
					'workshop_attendees.workshop_id',
					'user_profiles.first_name',
					'user_profiles.last_name'
				])
				.where('workshop_attendees.id', '=', attendeeId)
				.where('workshop_attendees.workshop_id', '=', workshopId)
				.executeTakeFirst();

			if (!attendee) {
				throw new Error('Attendee not found');
			}

			// Check if already cancelled
			if (attendee.status === 'cancelled') {
				throw new Error('Attendee already cancelled');
			}

			// Update the attendee status to cancelled
			await trx
				.updateTable('workshop_attendees')
				.set({
					status: 'cancelled',
					cancelled_at: new Date().toISOString(),
					cancelled_by: session.user.id,
					refund_requested: requestRefund,
					waitlist_return_requested: moveToWaitlist
				})
				.where('id', '=', attendeeId)
				.execute();

			// If moving to waitlist, use the existing database function
			if (moveToWaitlist) {
				await moveCancelledAttendeeToWaitlist(
					attendeeId,
					workshopId,
					trx,
					reason || 'Cancelled by admin'
				);
			}

			return {
				attendee,
				hasPaid: !!attendee.paid_at,
				moveToWaitlist,
				requestRefund
			};
		});

		return json({
			success: true,
			message: 'Attendee cancelled successfully',
			data: result
		});
	} catch (e: any) {
		Sentry.captureException(e);

		if (e.message === 'Attendee not found') {
			throw error(404, 'Attendee not found');
		}

		if (e.message === 'Attendee already cancelled') {
			throw error(400, 'Attendee already cancelled');
		}

		throw error(500, e?.message || 'Failed to cancel attendee');
	}
};
