import { json, error } from '@sveltejs/kit';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';
import { getRolesFromSession } from '$lib/server/roles';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import type { Session } from '@supabase/supabase-js';

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
      // First, check if workshop exists and is in draft status
      const existingWorkshop = await trx
        .selectFrom('workshops')
        .select(['id', 'status'])
        .where('id', '=', workshopId)
        .executeTakeFirst();

      if (!existingWorkshop) {
        throw new Error('Workshop not found');
      }

      if (existingWorkshop.status !== 'draft') {
        throw new Error(`Workshop is already ${existingWorkshop.status} and cannot be published`);
      }

      // Update workshop status to published
      return await trx
        .updateTable('workshops')
        .set({ 
          status: 'published',
          updated_at: new Date().toISOString()
        })
        .where('id', '=', workshopId)
        .returningAll()
        .execute();
    });

    if (!updatedWorkshop) {
      throw error(500, 'Failed to update workshop');
    }

    // Call the workshop_inviter edge function
    try {
      const { error: edgeFunctionError } = await supabaseServiceClient.functions.invoke(
        'workshop_inviter',
        {
          body: { workshop_id: workshopId },
          headers: {
            Authorization: `Bearer ${(session as unknown as Session)?.access_token}`
          }
        }
      );

      if (edgeFunctionError) {
        Sentry.captureMessage(`Workshop inviter edge function error: ${JSON.stringify(edgeFunctionError)}`, 'error');
        // Note: We don't fail the request here as the workshop is already published
        // The edge function error is logged but we continue
        console.warn('Workshop published successfully but inviter function failed:', edgeFunctionError);
      }
    } catch (edgeFunctionError) {
      Sentry.captureMessage(`Error calling workshop inviter: ${edgeFunctionError}`, 'error');
      console.warn('Workshop published successfully but inviter function failed:', edgeFunctionError);
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
    
    if (e.message?.includes('already')) {
      throw error(400, e.message);
    }
    
    throw error(500, e?.message || 'Failed to publish workshop');
  }
}; 