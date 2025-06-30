import { json, error } from '@sveltejs/kit';
import { getKyselyClient } from '$lib/server/kysely';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ locals, platform }) => {
  // Check authentication
  const { session } = await locals.safeGetSession();
  if (!session) throw error(401, 'Not authenticated');

  const db = getKyselyClient(platform?.env.HYPERDRIVE);

  // Single join query: user_profiles JOIN user_roles ON user_profiles.supabase_user_id = user_roles.user_id
  const profiles = await db
    .selectFrom('user_profiles')
    .innerJoin('user_roles', 'user_profiles.supabase_user_id', 'user_roles.user_id')
    .select(['user_profiles.id', 'user_profiles.first_name', 'user_profiles.last_name'])
    .where('user_roles.role', '=', 'coach')
    .execute();

  return json(profiles);
}; 