import { json, error } from '@sveltejs/kit';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import type { RequestHandler } from './$types';
import * as v from 'valibot';
import * as Sentry from '@sentry/sveltekit';
import dayjs from 'dayjs';
import { getRolesFromSession } from '$lib/server/roles';

const createWorkshopSchema = v.object({
	workshop_date: v.pipe(
		v.string(),
		v.nonEmpty('Date required'),
		v.check((val) => dayjs(val, undefined, true).isValid(), 'Invalid date'),
		v.check(
			(val) => dayjs(val).isAfter(dayjs().subtract(1, 'minute')),
			'Date cannot be in the past'
		)
	),
	location: v.pipe(v.string(), v.nonEmpty('Location required')),
	coach_id: v.pipe(v.string(), v.nonEmpty('Coach required')),
	capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
	notes_md: v.optional(v.string())
});

export const POST: RequestHandler = async ({ request, locals, platform }) => {
	// Check authentication
	const { session } = await locals.safeGetSession();
	if (!session) throw error(401, 'Not authenticated');

	// Role check
	const roles = getRolesFromSession(session) as Set<string>;
	const allowed = new Set(['admin', 'president', 'beginners_coordinator']);
	const intersection = new Set([...roles].filter((role) => allowed.has(role)));
	if (intersection.size === 0) {
		throw error(403, 'Insufficient permissions');
	}
	let body: unknown;
	try {
		body = await request.json();
	} catch (err) {
		Sentry.captureException(err);
		throw error(400, 'Invalid JSON');
	}

	const parsed = v.safeParse(createWorkshopSchema, body);
	if (!parsed.success) {
		Sentry.captureException(parsed.issues);
		throw error(400, 'Validation failed: ' + JSON.stringify(parsed.issues));
	}

	const db = getKyselyClient(platform?.env.HYPERDRIVE);

	const { workshop_date, location, coach_id, capacity, notes_md } = parsed.output;

	try {
		const [created] = await executeWithRLS(db, { claims: session }, async (trx) => {
			return await trx
				.insertInto('workshops')
				.values({
					workshop_date,
					location,
					coach_id,
					capacity,
					notes_md: notes_md ?? null,
					status: 'draft',
					batch_size: 16,
					cool_off_days: 5,
					stripe_price_key: null
				})
				.returningAll()
				.execute();
		});
		return json(created);
	} catch (e: any) {
		Sentry.captureException(e);
		throw error(500, e?.message || 'Failed to create workshop');
	}
};
