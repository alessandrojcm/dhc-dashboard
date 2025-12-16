import { serve } from "std/http/server";
import * as Sentry from "@sentry/deno";
import { db, sql } from "../_shared/db.ts";
import { corsHeaders } from "../_shared/cors.ts";
import * as v from "valibot";
import dayjs from "dayjs";

// Initialize Sentry for error tracking
Sentry.init({
	dsn: Deno.env.get("SENTRY_DSN"),
	environment: Deno.env.get("ENVIRONMENT") || "development",
});
type Workshop = {
	id: string;
	title: string;
	location: string;
	start_date: string;
	status: string;
	announce_discord: boolean;
	announce_email: boolean;
};
// Maximum number of messages to process in a single run
const BATCH_SIZE = 10;

// Workshop announcement payload schema
const workshopAnnouncementSchema = v.object({
	workshop_id: v.pipe(v.string(), v.uuid()),
	announcement_type: v.picklist([
		"created",
		"status_changed",
		"time_changed",
		"location_changed",
	]),
	queued_at: v.string(),
});

/**
 * Verifies if the provided bearer token matches the service role key stored in the vault
 */
async function verifyBearerToken(authHeader: string | null): Promise<boolean> {
	if (!authHeader || !authHeader.startsWith("Bearer ")) {
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
			console.error("Service role key not found in vault");
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

async function processWorkshopAnnouncementQueue() {
	console.log("Processing workshop announcement queue...");

	try {
		// Read up to BATCH_SIZE messages from the queue
		const messages = await sql<{
			msg_id: string;
			message: string;
		}>`
			WITH msgs AS (SELECT *
										FROM pgmq.read('workshop_announcement', 30, ${BATCH_SIZE}))
			SELECT *
			FROM msgs
		`.execute(db);

		const rows = messages.rows;
		console.log(`Found ${rows.length} workshop announcements to process`);

		if (rows.length === 0) {
			return { processed: 0 };
		}

		// Parse and validate all messages first
		const validWorkshops: Array<{
			msgId: string;
			workshop_id: string;
			announcement_type: string;
		}> = [];

		for (const row of rows) {
			try {
				const msgId = row.msg_id;
				const msg = row.message;
				const payload = v.safeParse(workshopAnnouncementSchema, msg);

				if (!payload.success) {
					Sentry.captureMessage(
						`Invalid workshop announcement message: ${JSON.stringify(
							msg,
						)}, errors: ${JSON.stringify(payload.issues)}`,
						"error",
					);
					await sql`SELECT * FROM pgmq.archive('workshop_announcement', ${msgId}::bigint)`.execute(
						db,
					);
					continue;
				}

				validWorkshops.push({
					msgId,
					workshop_id: payload.output.workshop_id,
					announcement_type: payload.output.announcement_type,
				});
			} catch (error) {
				console.error(`Error parsing workshop announcement message: ${error}`);
				Sentry.captureException(error);
			}
		}

		if (validWorkshops.length === 0) {
			return { processed: 0 };
		}

		// Get all workshop details in one query
		const workshopIds = validWorkshops.map((w) => w.workshop_id);
		const workshopsResult = await sql<Workshop>`
			SELECT id, title, location, start_date, status, announce_discord, announce_email
			FROM club_activities
			WHERE id = ANY(${workshopIds})
		`.execute(db);

		const workshopsMap = new Map(workshopsResult.rows.map((w) => [w.id, w]));

		// Group workshops by announcement settings
		const discordWorkshops: Array<{
			workshop: Workshop;
			announcement_type: string;
		}> = [];
		const emailWorkshops: Array<{
			workshop: Workshop;
			announcement_type: string;
		}> = [];

		for (const validWorkshop of validWorkshops) {
			const workshop = workshopsMap.get(validWorkshop.workshop_id);
			if (!workshop) {
				console.error(`Workshop ${validWorkshop.workshop_id} not found`);
				continue;
			}

			if (workshop.announce_discord) {
				discordWorkshops.push({
					workshop,
					announcement_type: validWorkshop.announcement_type,
				});
			}
			if (workshop.announce_email) {
				emailWorkshops.push({
					workshop,
					announcement_type: validWorkshop.announcement_type,
				});
			}
		}

		// Create batched Discord message if there are workshops to announce
		if (discordWorkshops.length > 0) {
			const batchedMessage = createBatchedMessage(discordWorkshops);
			const discordMessage = {
				message: batchedMessage,
				workshop_count: discordWorkshops.length,
				announcement_type: "batched",
			};

			await sql`
				SELECT pgmq.send('discord_queue', ${JSON.stringify(discordMessage)})
			`.execute(db);

			console.log(
				`Queued batched Discord message for ${discordWorkshops.length} workshops`,
			);
		}

		// Create batched email messages if there are workshops to announce
		if (emailWorkshops.length > 0) {
			const batchedMessage = createBatchedMessage(emailWorkshops);

			// Get active users for announcements
			const usersResult = await sql<{
				user_id: string;
				email: string;
				first_name: string;
				last_name: string;
			}>`
				SELECT 
					up.supabase_user_id as user_id, 
					au.email, 
					up.first_name, 
					up.last_name
				FROM user_profiles up
				LEFT JOIN auth.users au ON up.supabase_user_id = au.id
				WHERE up.is_active = true AND au.email IS NOT NULL
			`.execute(db);

			const users = usersResult.rows;
			console.log(`Found ${users.length} active users for email announcements`);

			const emailQueue = [];
			for (const user of users) {
				const emailMessage = {
					transactionalId: "workshopAnnouncement",
					email: user.email,
					dataVariables: {
						first_name: user.first_name,
						last_name: user.last_name,
						message: batchedMessage,
						workshop_count: emailWorkshops.length,
					},
				};
				emailQueue.push(emailMessage);
			}

			await sql`
				select *
				from pgmq.send_batch(
					'email_queue',
					${emailQueue}::jsonb[]
				)
			`.execute(db);

			console.log(
				`Queued ${users.length} batched email messages for ${emailWorkshops.length} workshops`,
			);
		}

		// Archive all processed messages
		for (const validWorkshop of validWorkshops) {
			await sql`SELECT * FROM pgmq.archive('workshop_announcement', ${validWorkshop.msgId}::bigint)`.execute(
				db,
			);
		}

		return { processed: validWorkshops.length };
	} catch (error) {
		console.error(`Error reading from workshop announcement queue: ${error}`);
		Sentry.captureException(error);
		return { error: error.message };
	}
}

// Create a batched message from multiple workshops
function createBatchedMessage(
	workshops: Array<{ workshop: Workshop; announcement_type: string }>,
): string {
	if (workshops.length === 0) return "";

	const lines: string[] = [];

	// Group by announcement type for better organization
	const groupedByType = workshops.reduce(
		(acc, { workshop, announcement_type }) => {
			if (!acc[announcement_type]) acc[announcement_type] = [];
			acc[announcement_type].push(workshop);
			return acc;
		},
		{} as Record<string, Workshop[]>,
	);

	// Add header
	lines.push("🗡️ **Workshop Updates** 🗡️\n");

	// Process each announcement type
	for (const [announcementType, workshopList] of Object.entries(
		groupedByType,
	)) {
		if (workshopList.length === 0) continue;

		// Add section header based on type
		switch (announcementType) {
			case "created":
			case "status_changed": {
				const newWorkshops = workshopList.filter((w) => w.status === "planned");
				const publishedWorkshops = workshopList.filter(
					(w) => w.status === "published",
				);
				const cancelledWorkshops = workshopList.filter(
					(w) => w.status === "cancelled",
				);

				if (newWorkshops.length > 0) {
					lines.push("📅 **New Workshops Being Planned:**");
					for (const workshop of newWorkshops) {
						const workshopDate = dayjs(workshop.start_date).format(
							"MMMM D, YYYY [at] h:mm A",
						);
						lines.push(
							`• ${workshop.title} on ${workshopDate} at ${workshop.location}`,
						);
					}
					lines.push('Head to "My Workshops" to express your interest!\n');
				}

				if (publishedWorkshops.length > 0) {
					lines.push("🎯 **Registration Now Open:**");
					for (const workshop of publishedWorkshops) {
						const workshopDate = dayjs(workshop.start_date).format(
							"MMMM D, YYYY [at] h:mm A",
						);
						lines.push(
							`• ${workshop.title} on ${workshopDate} at ${workshop.location}`,
						);
					}
					lines.push('Head to "My Workshops" to register!\n');
				}

				if (cancelledWorkshops.length > 0) {
					lines.push("❌ **Cancelled Workshops:**");
					for (const workshop of cancelledWorkshops) {
						const workshopDate = dayjs(workshop.start_date).format(
							"MMMM D, YYYY [at] h:mm A",
						);
						lines.push(
							`• ${workshop.title} scheduled for ${workshopDate} has been cancelled`,
						);
					}
					lines.push("");
				}
				break;
			}

			case "time_changed":
				lines.push("⏰ **Schedule Changes:**");
				for (const workshop of workshopList) {
					const workshopDate = dayjs(workshop.start_date).format(
						"MMMM D, YYYY [at] h:mm A",
					);
					lines.push(
						`• ${workshop.title} is now scheduled for ${workshopDate} at ${workshop.location}`,
					);
				}
				lines.push("");
				break;

			case "location_changed":
				lines.push("📍 **Location Changes:**");
				for (const workshop of workshopList) {
					const workshopDate = dayjs(workshop.start_date).format(
						"MMMM D, YYYY [at] h:mm A",
					);
					lines.push(
						`• ${workshop.title} on ${workshopDate} will now be held at ${workshop.location}`,
					);
				}
				lines.push("");
				break;
		}
	}

	return lines.join("\n").trim();
}

serve(async (req) => {
	// Handle CORS preflight requests
	if (req.method === "OPTIONS") {
		return new Response("ok", { headers: corsHeaders });
	}

	if (req.method !== "POST") {
		return new Response(JSON.stringify({ error: "Method not allowed" }), {
			status: 405,
			headers: { "Content-Type": "application/json", ...corsHeaders },
		});
	}

	try {
		// Verify the bearer token
		const isAuthorized = await verifyBearerToken(
			req.headers.get("Authorization"),
		);
		if (!isAuthorized) {
			return new Response(JSON.stringify({ error: "Unauthorized" }), {
				status: 401,
				headers: { "Content-Type": "application/json", ...corsHeaders },
			});
		}

		const result = processWorkshopAnnouncementQueue();
		EdgeRuntime.waitUntil(result);

		return new Response(JSON.stringify(result), {
			headers: {
				...corsHeaders,
				"Content-Type": "application/json",
			},
			status: 200,
		});
	} catch (error) {
		console.error(`Unhandled error: ${error}`);
		Sentry.captureException(error);

		return new Response(JSON.stringify({ error: "Internal server error" }), {
			headers: {
				...corsHeaders,
				"Content-Type": "application/json",
			},
			status: 500,
		});
	}
});
