import { serve } from 'std/http/server';
import * as Sentry from '@sentry/deno';
import { db, sql } from '../_shared/db.ts';
import { corsHeaders } from '../_shared/cors.ts';
import * as v from 'valibot';

// Initialize Sentry for error tracking
Sentry.init({
	dsn: Deno.env.get('SENTRY_DSN'),
	environment: Deno.env.get('ENVIRONMENT') || 'development'
});

const isDevelopment = Deno.env.get('ENVIRONMENT') === 'development';
const DISCORD_WEBHOOK_URL = Deno.env.get('DISCORD_WEBHOOK_URL');

// Maximum number of messages to process in a single run
const BATCH_SIZE = 10;

// Discord message payload schema
const discordMessageSchema = v.object({
	message: v.string(),
	workshop_id: v.pipe(v.string(), v.uuid()),
	announcement_type: v.picklist(['created', 'status_changed', 'time_changed', 'location_changed'])
});

/**
 * Verifies if the provided bearer token matches the service role key stored in the vault
 */
async function verifyBearerToken(authHeader: string | null): Promise<boolean> {
	if (!authHeader || !authHeader.startsWith('Bearer ')) {
		return false;
	}

	const token = authHeader.substring(7);

	try {
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

/**
 * Send message to Discord webhook
 */
async function sendDiscordMessage(message: string): Promise<boolean> {
	if (!DISCORD_WEBHOOK_URL) {
		console.error('Discord webhook URL not configured');
		return false;
	}

	try {
		const response = await fetch(DISCORD_WEBHOOK_URL, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				content: `Hey @everyone!\n${message}`,
				allowed_mentions: {
					parse: ['everyone']
				}
			})
		});

		if (!response.ok) {
			console.error(`Discord webhook failed: ${response.status} ${response.statusText}`);
			return false;
		}

		return true;
	} catch (error) {
		console.error(`Error sending Discord message: ${error}`);
		Sentry.captureException(error);
		return false;
	}
}

async function processDiscordQueue() {
	console.log('Processing Discord queue...');

	try {
		// Read up to BATCH_SIZE messages from the queue
		const messages = await sql<{
			msg_id: string;
			message: string;
		}>`
			WITH msgs AS (SELECT *
										FROM pgmq.read('discord_queue', 30, ${BATCH_SIZE}))
			SELECT *
			FROM msgs
		`.execute(db);

		const rows = messages.rows;
		console.log(`Found ${rows.length} Discord messages to process`);

		if (rows.length === 0) {
			return { processed: 0 };
		}

		// Process each message
		for (const row of rows) {
			try {
				const msgId = row.msg_id;
				const msg = row.message;
				const payload = v.safeParse(discordMessageSchema, msg);

				if (!payload.success) {
					Sentry.captureMessage(
						`Invalid Discord queue message: ${JSON.stringify(msg)}, errors: ${JSON.stringify(
							payload.issues
						)}`,
						'error'
					);
					await sql`SELECT * FROM pgmq.archive('discord_queue', ${msgId}::bigint)`.execute(db);
					continue;
				}

				console.log(`Processing Discord message ${msgId}: ${JSON.stringify(msg)}`);

				const { message, workshop_id, announcement_type } = payload.output;

				if (isDevelopment) {
					console.log(`Skipping Discord send in development mode: ${message}`);
					console.log(`Workshop ID: ${workshop_id}, Type: ${announcement_type}`);
				} else {
					// Send the Discord message
					const success = await sendDiscordMessage(message);

					if (!success) {
						console.error(`Failed to send Discord message for workshop ${workshop_id}`);
						// Don't archive the message so it can be retried
						continue;
					}

					console.log(`Discord message sent for workshop ${workshop_id}`);
				}

				// Archive the message after successful processing
				await sql`SELECT * FROM pgmq.archive('discord_queue', ${msgId}::bigint)`.execute(db);
			} catch (error) {
				console.error(`Error processing Discord message: ${error}`);
				Sentry.captureException(error);
				// Don't delete the message if there was an error, so it can be retried
			}
		}

		return { processed: rows.length };
	} catch (error) {
		console.error(`Error reading from Discord queue: ${error}`);
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

		const result = await processDiscordQueue();

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
