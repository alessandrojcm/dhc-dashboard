import * as Sentry from '@sentry/sveltekit';
import { error, json, type RequestHandler } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth.js';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely.js';

export const POST: RequestHandler = async ({ locals, params, platform }) => {
	try {
		// All authenticated users are members and can express interest
		const session = await authorize(locals, new Set(['member']));

		if (!platform?.env?.HYPERDRIVE) {
			throw error(500, 'Platform configuration missing');
		}

		const kysely = getKyselyClient(platform.env.HYPERDRIVE);

		const workshopId = params.id;

		if (!workshopId) {
			throw error(400, 'Workshop ID is required');
		}

		// Check if workshop exists and is in 'planned' status
		const workshop = await executeWithRLS(kysely, { claims: session }, (db) =>
			db.selectFrom('club_activities').selectAll().where('id', '=', workshopId).executeTakeFirst()
		);

		if (!workshop) {
			throw error(404, 'Workshop not found');
		}

		if (workshop.status !== 'planned') {
			throw error(400, 'Can only express interest in planned workshops');
		}

		// Check if user already expressed interest
		const existingInterest = await executeWithRLS(kysely, { claims: session }, (db) =>
			db
				.selectFrom('club_activity_interest')
				.selectAll()
				.where('club_activity_id', '=', workshopId)
				.where('user_id', '=', session.user.id)
				.executeTakeFirst()
		);

		if (existingInterest) {
			// Withdraw interest (toggle behavior)
			await executeWithRLS(kysely, { claims: session }, (db) =>
				db.deleteFrom('club_activity_interest').where('id', '=', existingInterest.id).execute()
			);

			return json({
				success: true,
				interest: null,
				message: 'Interest withdrawn successfully'
			});
		} else {
			// Express interest
			const newInterest = await executeWithRLS(kysely, { claims: session }, (db) =>
				db
					.insertInto('club_activity_interest')
					.values({
						club_activity_id: workshopId,
						user_id: session.user.id
					})
					.returningAll()
					.executeTakeFirst()
			);

			return json({
				success: true,
				interest: newInterest,
				message: 'Interest expressed successfully'
			});
		}
	} catch (err) {
		Sentry.captureException(err);
		console.error('Error managing workshop interest:', err);

		if (err && typeof err === 'object' && 'status' in err) {
			throw err;
		}

		throw error(500, 'Failed to manage workshop interest');
	}
};
