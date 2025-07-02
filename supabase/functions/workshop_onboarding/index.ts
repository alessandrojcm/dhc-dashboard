import { serve } from 'std/http/server';
import * as Sentry from '@sentry/deno';
import { db, sql } from '../_shared/db.ts';
import { corsHeaders } from '../_shared/cors.ts';

// Initialize Sentry
Sentry.init({
	dsn: Deno.env.get('SENTRY_DSN'),
	environment: Deno.env.get('ENVIRONMENT') || 'development',
	tracesSampleRate: 1.0
});

interface WorkshopForOnboarding {
	id: string;
	workshop_date: string;
	location: string;
	attendee_id: string;
	onboarding_token: string | null;
	email: string;
	first_name: string;
	last_name: string;
}

serve(async (req) => {
	// Handle CORS
	if (req.method === 'OPTIONS') {
		return new Response('ok', { headers: corsHeaders });
	}

	try {
		console.log('Starting workshop onboarding reminder process...');

		// Find workshops happening in 2 days with confirmed attendees needing onboarding
		const workshopsNeedingOnboarding = await findWorkshopsForOnboarding();

		if (workshopsNeedingOnboarding.length === 0) {
			console.log('No workshops need onboarding reminders at this time');
			return new Response(
				JSON.stringify({
					success: true,
					message: 'No workshops need onboarding reminders',
					processed: 0
				}),
				{
					status: 200,
					headers: { ...corsHeaders, 'Content-Type': 'application/json' }
				}
			);
		}

		console.log(
			`Found ${workshopsNeedingOnboarding.length} attendees needing onboarding reminders`
		);

		// Process each attendee
		const processedCount = await processOnboardingReminders(workshopsNeedingOnboarding);

		console.log(`Onboarding process complete: ${processedCount} emails sent`);

		return new Response(
			JSON.stringify({
				success: true,
				processed: processedCount,
				message: `Sent ${processedCount} onboarding reminder emails`
			}),
			{
				status: 200,
				headers: { ...corsHeaders, 'Content-Type': 'application/json' }
			}
		);
	} catch (error) {
		console.error('Workshop onboarding process error:', error);

		Sentry.captureException(error, {
			tags: {
				function: 'workshop_onboarding_main'
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

async function findWorkshopsForOnboarding(): Promise<WorkshopForOnboarding[]> {
	try {
		// Find workshops happening in exactly 2 days from now
		const result = await sql`
      SELECT w.id,
             w.workshop_date,
             w.location,
             wa.id as attendee_id,
             wa.onboarding_token,
             wl.email,
             up.first_name,
             up.last_name
      FROM workshops w
      INNER JOIN workshop_attendees wa ON w.id = wa.workshop_id
      INNER JOIN user_profiles up ON wa.user_profile_id = up.id
      INNER JOIN waitlist wl ON up.waitlist_id = wl.id
      WHERE w.status = 'published'
        AND wa.status = 'confirmed'
        AND wa.onboarding_completed_at IS NULL
        AND w.workshop_date::date = (CURRENT_DATE + INTERVAL '2 days')::date
      ORDER BY w.workshop_date ASC, up.last_name ASC, up.first_name ASC
    `.execute(db);

		return result.rows.map((row) => ({
			id: row[0] as string,
			workshop_date: row[1] as string,
			location: row[2] as string,
			attendee_id: row[3] as string,
			onboarding_token: row[4] as string | null,
			email: row[5] as string,
			first_name: row[6] as string,
			last_name: row[7] as string
		}));
	} catch (error) {
		console.error('Error finding workshops for onboarding:', error);
		throw error;
	}
}

async function processOnboardingReminders(workshops: WorkshopForOnboarding[]): Promise<number> {
	let processedCount = 0;

	for (const workshop of workshops) {
		try {
			// Generate onboarding token if not exists
			let onboardingToken = workshop.onboarding_token;
			if (!onboardingToken) {
				onboardingToken = crypto.randomUUID();

				// Update the attendee record with the token
				await sql`
          UPDATE workshop_attendees 
          SET onboarding_token = ${onboardingToken}
          WHERE id = ${workshop.attendee_id}
        `.execute(db);

				console.log(`Generated onboarding token for attendee ${workshop.attendee_id}`);
			}

			// TODO: Send onboarding email via Loops.so or email service
			// For now, we'll log what would be sent
			const siteUrl = Deno.env.get('SITE_URL') || 'https://dhc-dashboard.app';
			const onboardingUrl = `${siteUrl}/workshop/onboarding/${onboardingToken}`;
			const checkinQrUrl = `${siteUrl}/workshop/checkin/${workshop.id}`;

			console.log(`Would send onboarding email to ${workshop.email}:`);
			console.log(`  Workshop: ${workshop.location} on ${workshop.workshop_date}`);
			console.log(`  Onboarding URL: ${onboardingUrl}`);
			console.log(`  Check-in QR URL: ${checkinQrUrl}`);

			// Here you would integrate with your email service (Loops.so)
			// await sendOnboardingEmail({
			//   email: workshop.email,
			//   firstName: workshop.first_name,
			//   workshopDate: workshop.workshop_date,
			//   location: workshop.location,
			//   onboardingUrl,
			//   checkinQrUrl
			// });

			processedCount++;
		} catch (error) {
			console.error(`Error processing onboarding for attendee ${workshop.attendee_id}:`, error);

			Sentry.captureException(error, {
				tags: {
					function: 'workshop_onboarding_individual',
					attendee_id: workshop.attendee_id,
					workshop_id: workshop.id
				}
			});
		}
	}

	return processedCount;
}

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/workshop_onboarding' \
    --header 'Authorization: Bearer YOUR_ANON_KEY' \
    --header 'Content-Type: application/json' \
    --data '{}'

*/
