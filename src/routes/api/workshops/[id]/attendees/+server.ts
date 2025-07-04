import { json, error } from '@sveltejs/kit';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import type { RequestHandler } from './$types';
import * as v from 'valibot';
import * as Sentry from '@sentry/sveltekit';
import { getRolesFromSession } from '$lib/server/roles';

const addAttendeeSchema = v.object({
  user_profile_id: v.pipe(v.string(), v.nonEmpty('User profile ID required')),
  priority: v.optional(v.number(), 1) // Default to priority 1 for manual additions
});

const getAttendeesQuerySchema = v.object({
  status: v.optional(v.union([
    v.literal('all'),
    v.literal('invited'),
    v.literal('confirmed'),
    v.literal('attended'),
    v.literal('cancelled'),
    v.literal('no_show')
  ]), 'all')
});

export const GET: RequestHandler = async ({ params, url, locals, platform }) => {
  // Check authentication
  const { session } = await locals.safeGetSession();
  if (!session) throw error(401, 'Not authenticated');
  
  // Role check - allow broader access for viewing attendees
  const roles = getRolesFromSession(session) as Set<string>;
  const allowed = new Set(['admin', 'president', 'beginners_coordinator', 'committee', 'coach']);
  const intersection = new Set([...roles].filter((role) => allowed.has(role)));
  if (intersection.size === 0) {
    throw error(403, 'Insufficient permissions');
  }

  const workshopId = params.id;
  if (!workshopId) {
    throw error(400, 'Workshop ID required');
  }

  // Validate query parameters
  const statusFilter = url.searchParams.get('status') || 'all';
  const validation = v.safeParse(getAttendeesQuerySchema, { status: statusFilter });
  
  if (!validation.success) {
    throw error(400, 'Invalid status filter: ' + JSON.stringify(validation.issues));
  }

  const { status } = validation.output;

  const db = getKyselyClient(platform?.env.HYPERDRIVE);
  if (!db) {
    throw error(500, 'Database connection failed');
  }

  try {
    const attendees = await executeWithRLS(db, { claims: session }, async (trx) => {
      let query = trx
        .selectFrom('workshop_attendees')
        .leftJoin('user_profiles', 'workshop_attendees.user_profile_id', 'user_profiles.id')
        .select([
          'workshop_attendees.id',
          'workshop_attendees.status',
          'workshop_attendees.invited_at',
          'workshop_attendees.user_profile_id',
          'workshop_attendees.checked_in_at',
          'workshop_attendees.paid_at',
          'workshop_attendees.onboarding_completed_at',
          'workshop_attendees.cancelled_at',
          'workshop_attendees.refund_processed_at',
          'workshop_attendees.refund_requested',
          'workshop_attendees.stripe_refund_id',
          'user_profiles.first_name',
          'user_profiles.last_name'
        ])
        .where('workshop_attendees.workshop_id', '=', workshopId);

      // Apply status filter if not 'all'
      if (status !== 'all') {
        query = query.where('workshop_attendees.status', '=', status as any);
      }

      return await query.execute();
    });

    // Transform the result to match the expected frontend format
    const transformedAttendees = attendees.map(row => ({
      id: row.id,
      status: row.status,
      invited_at: row.invited_at,
      user_profile_id: row.user_profile_id,
      checked_in_at: row.checked_in_at,
      paid_at: row.paid_at,
      onboarding_completed_at: row.onboarding_completed_at,
      cancelled_at: row.cancelled_at,
      refund_processed_at: row.refund_processed_at,
      refund_requested: row.refund_requested,
      stripe_refund_id: row.stripe_refund_id,
      user_profiles: {
        first_name: row.first_name,
        last_name: row.last_name
      }
    }));

    return json(transformedAttendees);

  } catch (e: any) {
    Sentry.captureException(e);
    throw error(500, e?.message || 'Failed to fetch attendees');
  }
};

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
  if (!workshopId) {
    throw error(400, 'Workshop ID required');
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

  const parsed = v.safeParse(addAttendeeSchema, body);
  if (!parsed.success) {
    Sentry.captureException(parsed.issues);
    throw error(400, 'Validation failed: ' + JSON.stringify(parsed.issues));
  }
  const { user_profile_id, priority } = parsed.output;

  try {
    const [addedAttendee] = await executeWithRLS(db, { claims: session }, async (trx) => {
      // First, verify the workshop exists
      const workshop = await trx
        .selectFrom('workshops')
        .select(['id', 'status', 'capacity'])
        .where('id', '=', workshopId)
        .executeTakeFirst();

      if (!workshop) {
        throw new Error('Workshop not found');
      }

      // Check if user_profile exists
      const userProfile = await trx
        .selectFrom('user_profiles')
        .select(['id', 'first_name', 'last_name'])
        .where('id', '=', user_profile_id)
        .executeTakeFirst();

      if (!userProfile) {
        throw new Error('User profile not found');
      }

      // Check if user is already in this workshop
      const existingAttendee = await trx
        .selectFrom('workshop_attendees')
        .select(['id'])
        .where('workshop_id', '=', workshopId)
        .where('user_profile_id', '=', user_profile_id)
        .executeTakeFirst();

      if (existingAttendee) {
        throw new Error('User is already an attendee of this workshop');
      }

      // Add the attendee with "invited" status (emails will be sent when workshop is published)
      return await trx
        .insertInto('workshop_attendees')
        .values({
          workshop_id: workshopId,
          user_profile_id,
          status: 'invited',
          priority: priority ?? 1,
          invited_at: null, // Will be set when workshop is published and emails are sent
          payment_url_token: null // Will be generated when workshop is published
        })
        .returningAll()
        .execute();
    });

    return json({
      success: true,
      attendee: addedAttendee
    });

  } catch (e: any) {
    Sentry.captureException(e);
    
    if (e.message === 'Workshop not found') {
      throw error(404, 'Workshop not found');
    }
    
    if (e.message === 'User profile not found') {
      throw error(404, 'User profile not found');
    }
    
    if (e.message === 'User is already an attendee of this workshop') {
      throw error(409, 'User is already an attendee of this workshop');
    }
    
    
    throw error(500, e?.message || 'Failed to add attendee');
  }
};

export const DELETE: RequestHandler = async ({ params, url, locals, platform }) => {
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
  const attendeeId = url.searchParams.get('attendee_id');
  
  if (!workshopId) {
    throw error(400, 'Workshop ID required');
  }
  
  if (!attendeeId) {
    throw error(400, 'Attendee ID required');
  }

  const db = getKyselyClient(platform?.env.HYPERDRIVE);
  if (!db) {
    throw error(500, 'Database connection failed');
  }

  try {
    await executeWithRLS(db, { claims: session }, async (trx) => {
      // First, verify the workshop exists
      const workshop = await trx
        .selectFrom('workshops')
        .select(['id', 'status'])
        .where('id', '=', workshopId)
        .executeTakeFirst();

      if (!workshop) {
        throw new Error('Workshop not found');
      }

      // Delete the attendee
      const deletedCount = await trx
        .deleteFrom('workshop_attendees')
        .where('id', '=', attendeeId)
        .where('workshop_id', '=', workshopId)
        .executeTakeFirst();

      if (!deletedCount.numDeletedRows || Number(deletedCount.numDeletedRows) === 0) {
        throw new Error('Attendee not found in this workshop');
      }
    });

    return json({
      success: true,
      message: 'Attendee removed successfully'
    });

  } catch (e: any) {
    Sentry.captureException(e);
    
    if (e.message === 'Workshop not found') {
      throw error(404, 'Workshop not found');
    }
    
    if (e.message === 'Attendee not found in this workshop') {
      throw error(404, 'Attendee not found in this workshop');
    }
    
    
    throw error(500, e?.message || 'Failed to remove attendee');
  }
}; 