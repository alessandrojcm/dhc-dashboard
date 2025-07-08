import { json, error } from '@sveltejs/kit';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';
import { getRolesFromSession } from '$lib/server/roles';

export const PATCH: RequestHandler = async ({ params, locals, platform }) => {
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
  if (!workshopId) {
    throw error(400, 'Workshop ID required');
  }

  const db = getKyselyClient(platform?.env.HYPERDRIVE);
  if (!db) {
    throw error(500, 'Database connection failed');
  }

  try {
    // Update workshop status and fetch updated workshop data
    const [updatedWorkshop] = await executeWithRLS(db, { claims: session }, async (trx) => {
      // First, check if workshop exists and is in published status
      const existingWorkshop = await trx
        .selectFrom('workshops')
        .select(['id', 'status'])
        .where('id', '=', workshopId)
        .executeTakeFirst();

      if (!existingWorkshop) {
        throw new Error('Workshop not found');
      }

      if (existingWorkshop.status !== 'published') {
        throw new Error(`Workshop is ${existingWorkshop.status} and cannot be finished. Only published workshops can be finished.`);
      }

      // Check if there are any attendees with pending status
      const pendingAttendees = await trx
        .selectFrom('workshop_attendees')
        .select(['id'])
        .where('workshop_id', '=', workshopId)
        .where('status', 'in', ['invited', 'pending'])
        .execute();

      if (pendingAttendees.length > 0) {
        throw new Error('Workshop cannot be finished while there are attendees with pending or invited status');
      }

      // Update workshop status to finished
      return await trx
        .updateTable('workshops')
        .set({ 
          status: 'finished',
          updated_at: new Date().toISOString()
        })
        .where('id', '=', workshopId)
        .returningAll()
        .execute();
    });

    if (!updatedWorkshop) {
      throw error(500, 'Failed to update workshop');
    }

    return json({
      success: true,
      workshop: updatedWorkshop
    });

  } catch (e: any) {
    Sentry.captureException(e);
    
    if (e.message === 'Workshop not found') {
      throw error(404, 'Workshop not found');
    }
    
    if (e.message?.includes('cannot be finished') || e.message?.includes('pending')) {
      throw error(400, e.message);
    }
    
    throw error(500, e?.message || 'Failed to finish workshop');
  }
}; 