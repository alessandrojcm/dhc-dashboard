import { serve } from 'std/http/server';
import * as Sentry from '@sentry/deno';
import { db, sql } from '../_shared/db.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { createClient } from '@supabase/supabase-js';

// Initialize Sentry
Sentry.init({
	dsn: Deno.env.get('SENTRY_DSN'),
	environment: Deno.env.get('ENVIRONMENT') || 'development',
	tracesSampleRate: 1.0
});

interface WorkshopToTopup {
	id: string;
	workshop_date: string;
	capacity: number;
	cool_off_days: number;
	location: string;
	current_attendees: number;
	last_batch_sent: string | null;
}

serve(async (req) => {
	// Handle CORS
	if (req.method === 'OPTIONS') {
		return new Response('ok', { headers: corsHeaders });
	}

	try {
		console.log('Starting workshop top-up scheduler...');

		// Find workshops that need top-up invitations
		const workshopsToTopup = await findWorkshopsNeedingTopup();

		if (workshopsToTopup.length === 0) {
			console.log('No workshops need top-up invitations at this time');
			return new Response(
				JSON.stringify({
					success: true,
					message: 'No workshops need top-up',
					processed: 0
				}),
				{
					status: 200,
					headers: { ...corsHeaders, 'Content-Type': 'application/json' }
				}
			);
		}

		console.log(`Found ${workshopsToTopup.length} workshops needing top-up`);
		const supabaseClient = createClient(
			Deno.env.get('SUPABASE_URL') ?? '',
			Deno.env.get('SUPABASE_ANON_KEY') ?? ''
		);
		// Process each workshop
		// Process all workshops in parallel using Promise.all
		const workshopPromises = workshopsToTopup.map(async (workshop) => {
			try {
				console.log(
					`Processing workshop ${workshop.id} - Available slots: ${workshop.capacity - workshop.current_attendees}`
				);
				const inviterResponse = await supabaseClient.functions.invoke('workshop_invite', {
					method: 'POST',
					body: JSON.stringify({
						workshop_id: workshop.id
					})
				});

				if (!inviterResponse.error) {
					const inviterResult = inviterResponse.data;
					console.log(
						`Workshop ${workshop.id}: Successfully sent ${inviterResult.successful_invites || 0} invitations`
					);
					return {
						workshop_id: workshop.id,
						success: true,
						invited: inviterResult.successful_invites || 0,
						message: `Successfully sent ${inviterResult.successful_invites || 0} invitations`
					};
				} else {
					console.error(`Workshop ${workshop.id}: Inviter API error:`, inviterResponse.error);
					return {
						workshop_id: workshop.id,
						success: false,
						error: `Inviter API error: ${inviterResponse.error}`
					};
				}
			} catch (error) {
				console.error(`Workshop ${workshop.id}: Error processing:`, error);

				Sentry.captureException(error, {
					tags: {
						function: 'workshop_topup_individual',
						workshop_id: workshop.id
					}
				});

				return {
					workshop_id: workshop.id,
					success: false,
					error: error
				};
			}
		});

		const results = await Promise.all(workshopPromises);

		const successCount = results.filter((r) => r.success).length;
		const totalInvited = results.reduce((sum, r) => sum + (r.invited || 0), 0);

		console.log(
			`Top-up complete: ${successCount}/${workshopsToTopup.length} workshops processed, ${totalInvited} total invitations sent`
		);

		return new Response(
			JSON.stringify({
				success: true,
				processed: workshopsToTopup.length,
				successful: successCount,
				total_invitations_sent: totalInvited,
				results
			}),
			{
				status: 200,
				headers: { ...corsHeaders, 'Content-Type': 'application/json' }
			}
		);
	} catch (error) {
		console.error('Workshop top-up scheduler error:', error);

		Sentry.captureException(error, {
			tags: {
				function: 'workshop_topup_main'
			}
		});

		return new Response(
			JSON.stringify({
				success: false,
				error: error.message
			}),
			{
				status: 500,
				headers: { ...corsHeaders, 'Content-Type': 'application/json' }
			}
		);
	}
});

async function findWorkshopsNeedingTopup(): Promise<WorkshopToTopup[]> {
	try {
		const result = await sql`
			SELECT w.id,
						 w.workshop_date,
						 w.capacity,
						 w.cool_off_days,
						 w.location,
						 COALESCE(attendee_counts.current_attendees, 0) as current_attendees,
						 last_invites.last_batch_sent
			FROM workshops w
						 LEFT JOIN (SELECT workshop_id,
															 COUNT(*) as current_attendees
												FROM workshop_attendees
												WHERE status IN ('invited', 'confirmed', 'attended')
												GROUP BY workshop_id) attendee_counts ON w.id = attendee_counts.workshop_id
						 LEFT JOIN (SELECT workshop_id,
															 MAX(invited_at) as last_batch_sent
												FROM workshop_attendees
												WHERE invited_at IS NOT NULL
												GROUP BY workshop_id) last_invites ON w.id = last_invites.workshop_id
			WHERE w.status = 'published'
				-- Workshop is in the future
				AND w.workshop_date > NOW()
				-- Workshop has available capacity
				AND COALESCE(attendee_counts.current_attendees, 0) < w.capacity
				-- Cool-off period has passed since last batch OR no batches sent yet
				AND (
				last_invites.last_batch_sent IS NULL
					OR last_invites.last_batch_sent <= (NOW() - INTERVAL '1 day' * w.cool_off_days)
				)
			ORDER BY w.workshop_date ASC
		`.execute(db);

		return result.rows.map((row) => ({
			id: row[0] as string,
			workshop_date: row[1] as string,
			capacity: row[2] as number,
			cool_off_days: row[3] as number,
			location: row[4] as string,
			current_attendees: row[5] as number,
			last_batch_sent: row[6] as string | null
		}));
	} catch (error) {
		console.error('Error finding workshops needing top-up:', error);
		throw error;
	}
}

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/workshop_topup' \
    --header 'Authorization: Bearer YOUR_ANON_KEY' \
    --header 'Content-Type: application/json' \
    --data '{}'

*/
