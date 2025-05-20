import { serve } from 'std/http/server';
import * as Sentry from '@sentry/deno';
import { db, sql } from '../_shared/db.ts';
import { corsHeaders } from '../_shared/cors.ts';
import * as v from 'valibot';
import { LoopsClient } from 'loops';

const transactionalEnumTitles = ['inviteMember'] as const;

export const transactionalIds: Record<string, string> = {
	inviteMember: Deno.env.get('INVITE_MEMBER_TRANSACTIONAL_ID') ?? 'invite_member'
} as const;

const loops = new LoopsClient(Deno.env.get('LOOPS_API_KEY')!);
const isDevelopment = Deno.env.get('ENVIRONMENT') === 'development';

const payloadSchema = v.object({
	transactionalId: v.picklist(transactionalEnumTitles),
	email: v.pipe(v.string(), v.email()),
	dataVariables: v.record(v.string(), v.string())
});

// Initialize Sentry for error tracking
Sentry.init({
	dsn: Deno.env.get('SENTRY_DSN'),
	environment: Deno.env.get('ENVIRONMENT') || 'development'
});

// Maximum number of messages to process in a single run
const BATCH_SIZE = 10;

/**
 * Verifies if the provided bearer token matches the service role key stored in the vault
 * @param authHeader The Authorization header from the request
 * @returns A boolean indicating if the token is valid
 */
async function verifyBearerToken(authHeader: string | null): Promise<boolean> {
	if (!authHeader || !authHeader.startsWith('Bearer ')) {
		return false;
	}

	const token = authHeader.substring(7); // Remove 'Bearer ' prefix

	try {
		// Query the vault.decrypted_secrets table to get the service role key
		const result = await sql<{ decrypted_secret: string }>`
			SELECT decrypted_secret 
			FROM vault.decrypted_secrets 
			WHERE name = 'service_role_key'
		`.execute(db);

		if (result.rows.length === 0) {
			console.error('Service role key not found in vault');
			return false;
		}

		const serviceRoleKey = result.rows[0].decrypted_secret;
		return token === serviceRoleKey;
	} catch (error) {
		console.error(`Error verifying bearer token: ${error}`);
		Sentry.captureException(error);
		return false;
	}
}

async function processEmailQueue() {
	console.log('Processing email queue...');

	try {
		// Read up to BATCH_SIZE messages from the queue
		const messages = await sql<{
			msg_id: string;
			message: string;
		}>`
			WITH msgs AS (SELECT *
										FROM pgmq.read('email_queue', 30, ${BATCH_SIZE}))
			SELECT *
			FROM msgs
		`.execute(db);

		const rows = messages.rows;
		console.log(`Found ${rows.length} messages to process`);

		if (rows.length === 0) {
			return { processed: 0 };
		}

		// Process each message
		for (const row of rows) {
			try {
				const msgId = row.msg_id;
				const msg = row.message;
				const payload = v.safeParse(payloadSchema, msg);
				if (!payload.success) {
					Sentry.captureMessage(
						`Invalid email queue message: ${JSON.stringify(msg)}, errors: ${JSON.stringify(
							payload.issues
						)}`,
						'error'
					);
					await sql`SELECT * FROM pgmq.archive('email_queue', ${msgId}::bigint)`.execute(db);
					continue;
				}

				console.log(`Processing message ${msgId}: ${JSON.stringify(msg)}`);

				// Extract email data from the message
				const email = payload.output.email;
				const transactionalId = payload.output.transactionalId;
				const dataVariables = payload.output.dataVariables;
				if (isDevelopment) {
					console.log(`Skipping email send in development mode: ${JSON.stringify(msg)}`);
					console.log(`Payload that would have been sent is: ${JSON.stringify(dataVariables)}`);
				} else {
					// Send the email
					await loops.sendTransactionalEmail({
						transactionalId: transactionalIds[transactionalId],
						email: email,
						dataVariables
					});
					console.log(`Email sent to ${email} with transactional ID ${transactionalId}`);
				}

				// Delete the message after successful processing
				await sql`SELECT * FROM pgmq.archive('email_queue', ${msgId}::bigint)`.execute(db);
			} catch (error) {
				console.error(`Error processing message: ${error}`);
				Sentry.captureException(error);
				// Don't delete the message if there was an error, so it can be retried
			}
		}

		return { processed: rows.length };
	} catch (error) {
		console.error(`Error reading from queue: ${error}`);
		Sentry.captureException(error);
		return { error: error.message };
	}
}

serve(async (req) => {
	// Handle CORS preflight requests
	if (req.method === 'OPTIONS') {
		return new Response('ok', { headers: corsHeaders });
	}

	if (req.method !== 'POST') {
		return new Response(JSON.stringify({ error: 'Method not allowed' }), {
			status: 405,
			headers: { 'Content-Type': 'application/json', ...corsHeaders }
		});
	}

	try {
		// Verify the bearer token
		const isAuthorized = await verifyBearerToken(req.headers.get('Authorization'));
		if (!isAuthorized) {
			return new Response(JSON.stringify({ error: 'Unauthorized' }), {
				status: 401,
				headers: { 'Content-Type': 'application/json', ...corsHeaders }
			});
		}

		const result = processEmailQueue();
		EdgeRuntime.waitUntil(result);

		return new Response(JSON.stringify(result), {
			headers: {
				...corsHeaders,
				'Content-Type': 'application/json'
			},
			status: 200
		});
	} catch (error) {
		console.error(`Unhandled error: ${error}`);
		Sentry.captureException(error);

		return new Response(JSON.stringify({ error: 'Internal server error' }), {
			headers: {
				...corsHeaders,
				'Content-Type': 'application/json'
			},
			status: 500
		});
	}
});
