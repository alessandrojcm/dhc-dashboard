import { json, error } from '@sveltejs/kit';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';
import { getRolesFromSession } from '$lib/server/roles';
import { sql } from 'kysely';

export const GET: RequestHandler = async ({ params, url, locals, platform }) => {
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
	const searchQuery = url.searchParams.get('q');

	if (!workshopId) {
		throw error(400, 'Workshop ID required');
	}

	if (!searchQuery || searchQuery.length < 2) {
		throw error(400, 'Search query too short. Minimum 2 characters required');
	}

	const db = getKyselyClient(platform?.env.HYPERDRIVE);
	if (!db) {
		throw error(500, 'Database connection failed');
	}

	try {
		const results = await executeWithRLS(db, { claims: session }, async (trx) => {
			// Use prefix matching for queries 3+ characters, exact matching for shorter queries
			const tsQuery =
				searchQuery.length >= 3
					? `${searchQuery
							.split(' ')
							.map((term) => `${term}:*`)
							.join(' & ')}`
					: searchQuery;

			const searchResults = await sql`
        SELECT DISTINCT
          up.id,
          CONCAT(up.first_name, ' ', up.last_name) as full_name,
          wv.email,
          wv.status
        FROM user_profiles up
        LEFT JOIN waitlist_management_view wv ON up.waitlist_id = wv.id
        WHERE up.search_text @@ to_tsquery('english', ${tsQuery})
        AND up.id NOT IN (
          SELECT user_profile_id 
          FROM workshop_attendees 
          WHERE workshop_id = ${workshopId}
        )
        ORDER BY full_name
        LIMIT 10
      `.execute(trx);

			return searchResults.rows.map((row: any) => ({
				id: row.id,
				full_name: row.full_name,
				email: row.email,
				status: row.status
			}));
		});

		return json(results);
	} catch (e: any) {
		Sentry.captureException(e);
		console.error('User search error:', e);
		throw error(500, e?.message || 'Failed to search users');
	}
};
