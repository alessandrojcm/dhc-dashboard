import { json, error } from '@sveltejs/kit';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import type { RequestHandler } from './$types';
import { onboardingSchema } from '$lib/schemas/workshopCreate';
import { SocialMediaConsent } from '$lib/types';
import * as v from 'valibot';
import * as Sentry from '@sentry/sveltekit';

export const POST: RequestHandler = async ({ request, platform }) => {
  const db = getKyselyClient(platform?.env.HYPERDRIVE);
  let body: unknown;
  
  try {
    body = await request.json();
  } catch (err) {
    Sentry.captureException(err);
    throw error(400, 'Invalid JSON');
  }

  const parsed = v.safeParse(onboardingSchema, body);
  if (!parsed.success) {
    Sentry.captureException(parsed.issues);
    throw error(400, 'Validation failed: ' + JSON.stringify(parsed.issues));
  }

  const { insuranceConfirmed, mediaConsent, signature } = parsed.output;
  
  // Get onboarding token from header
  const token = request.headers.get('x-onboarding-token');
  if (!token) {
    throw error(400, 'Missing onboarding token');
  }

  try {
    // We'll use a special session-like approach for token-based access
    // This is a simplified version that doesn't require full auth session
    const [updated] = await db.transaction().execute(async (trx) => {
      // Find attendee by token first
      const attendee = await trx
        .selectFrom('workshop_attendees')
        .selectAll()
        .where('onboarding_token', '=', token)
        .where('status', '=', 'confirmed')
        .executeTakeFirst();

      if (!attendee) {
        throw new Error('Invalid token or attendee not eligible for onboarding');
      }

      const now = new Date().toISOString();
      
      // Update attendee with onboarding completion
      return await trx
        .updateTable('workshop_attendees')
        .set({
          onboarding_completed_at: now,
          insurance_ok_at: insuranceConfirmed ? now : null,
          consent_media_at: (mediaConsent && mediaConsent !== SocialMediaConsent.no) ? now : null,
          signature_url: signature || null,
          status: 'pre_checked'
        })
        .where('id', '=', attendee.id)
        .returningAll()
        .execute();
    });

    return json({ success: true, attendee: updated });
  } catch (e: any) {
    Sentry.captureException(e);
    throw error(500, e?.message || 'Failed to complete onboarding');
  }
};