import { serve } from "std/http/server";
import { createClient } from "@supabase/supabase-js";
import dayjs from "dayjs";
import * as Sentry from "@sentry/deno";
import Stripe from "stripe";
import { db, sql } from "../_shared/db.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getRolesFromSession } from "../_shared/getRolesFromSession.ts";
import { createInvitation } from "./invitations.ts";
import { updateUserProfileWithCustomerId } from "./subscriptions.ts";

// Initialize Sentry
Sentry.init({
	dsn: Deno.env.get("SENTRY_DSN"),
	environment: Deno.env.get("ENVIRONMENT") || "development",
	tracesSampleRate: 1.0,
});

// Initialize Stripe client
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") || "", {
	apiVersion: "2025-06-30.basil",
	maxNetworkRetries: 3,
	timeout: 30 * 1000,
	httpClient: Stripe.createFetchHttpClient(),
});

// Define types for our application
type InviteData = {
	firstName: string;
	lastName: string;
	email: string;
	phoneNumber: string;
	dateOfBirth: string | Date;
};

function isInviteData(invite: InviteData | string): invite is InviteData {
	return typeof invite !== "string";
}

interface UserData {
	id: string;
	email?: string;
}

interface InviteResult {
	email: string;
	success: boolean;
	error?: string;
	invitationId?: string;
}

// Interface for price IDs
interface PriceIds {
	monthly: string;
	annual: string;
}

// Helper function to get price IDs from the settings table (cached) or from Stripe
async function getPriceIds(): Promise<PriceIds> {
	try {
		// First try to get from settings table (cached values)
		const cachedPrices = await getCachedPriceIds();
		if (cachedPrices) {
			return cachedPrices;
		}

		// If not cached or expired, fetch from Stripe
		const freshPrices = await fetchPriceIdsFromStripe();

		// Update cache
		await updatePriceCache(freshPrices);

		return freshPrices;
	} catch (error) {
		Sentry.captureException(error);
		throw new Error(
			`Failed to get price IDs: ${error instanceof Error ? error.message : String(error)}`,
		);
	}
}

// Get cached price IDs from the settings table
async function getCachedPriceIds(): Promise<PriceIds | null> {
	try {
		// Get both monthly and annual price IDs in a single query
		const priceData = await db
			.selectFrom("settings")
			.select(["key", "value", "updated_at"])
			.where("key", "in", ["stripe_monthly_price_id", "stripe_annual_price_id"])
			.execute();

		// Extract monthly and annual data from results
		const monthlyData = priceData.find(
			(item) => item.key === "stripe_monthly_price_id",
		);
		const annualData = priceData.find(
			(item) => item.key === "stripe_annual_price_id",
		);

		// If either data is missing, return null
		if (!monthlyData || !annualData) {
			return null;
		}

		// Check if cache is expired (older than 24 hours)
		const monthlyUpdatedAt = dayjs(monthlyData.updated_at);
		const annualUpdatedAt = dayjs(annualData.updated_at);
		const now = dayjs();

		if (
			now.diff(monthlyUpdatedAt, "hour") > 24 ||
			now.diff(annualUpdatedAt, "hour") > 24
		) {
			return null;
		}

		// Return cached price IDs
		return {
			monthly: monthlyData.value,
			annual: annualData.value,
		};
	} catch (error) {
		Sentry.captureException(error);
		return null;
	}
}

// Fetch price IDs directly from Stripe
async function fetchPriceIdsFromStripe(): Promise<PriceIds> {
	// Constants for lookup keys (same as in constants.ts)
	const MEMBERSHIP_FEE_LOOKUP_NAME =
		Deno.env.get("MEMBERSHIP_FEE_LOOKUP_NAME") ?? "standard_membership_fee";
	const ANNUAL_FEE_LOOKUP =
		Deno.env.get("ANNUAL_FEE_LOOKUP") ?? "annual_membership_fee_revised";

	// Fetch prices from Stripe in parallel
	const [monthlyPrices, annualPrices] = await Promise.all([
		stripe.prices.list({
			lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME],
			active: true,
			limit: 1,
		}),
		stripe.prices.list({
			lookup_keys: [ANNUAL_FEE_LOOKUP],
			active: true,
			limit: 1,
		}),
	]);

	// Extract price IDs
	const monthlyPriceId = monthlyPrices.data[0]?.id;
	const annualPriceId = annualPrices.data[0]?.id;

	if (!monthlyPriceId || !annualPriceId) {
		throw new Error("Failed to retrieve price IDs from Stripe");
	}

	return {
		monthly: monthlyPriceId,
		annual: annualPriceId,
	};
}

// Update the price cache in the settings table
async function updatePriceCache(prices: PriceIds): Promise<void> {
	const now = new Date().toISOString();

	// Update cache in parallel using kysely transaction
	await db.transaction().execute(async (trx) => {
		await Promise.all([
			trx
				.updateTable("settings")
				.set({
					value: prices.monthly,
					updated_at: now,
				})
				.where("key", "=", "stripe_monthly_price_id")
				.execute(),
			trx
				.updateTable("settings")
				.set({
					value: prices.annual,
					updated_at: now,
				})
				.where("key", "=", "stripe_annual_price_id")
				.execute(),
		]);
	});
}

/**
 * Process invitations in the background
 */
async function processInvitations(
	invites: (InviteData | string)[],
	user: UserData,
	supabaseAdmin: ReturnType<typeof createClient>,
	// eslint-disable-next-line @typescript-eslint/no-unused-vars
	_priceIds: { monthly: string; annual: string }, // Not used but kept for compatibility
) {
	console.log(
		`Starting background processing of ${invites.length} invitations`,
	);
	const results: InviteResult[] = [];
	const startTime = Date.now();

	try {
		// Process each invite
		for (const invite of invites) {
			let inviteData: InviteData = {} as InviteData; // Initialize to avoid 'used before assigned' errors
			try {
				// Process the invite in a transaction to ensure atomicity
				await db.transaction().execute(async (trx) => {
					if (isInviteData(invite)) {
						inviteData = invite;
					} else {
						const result = await trx
							.selectFrom("user_profiles")
							.select([
								"first_name",
								"last_name",
								"phone_number",
								"date_of_birth",
							])
							.where("waitlist_id", "=", invite)
							.leftJoin("waitlist", "waitlist.id", "user_profiles.waitlist_id")
							.select(["email"])
							.executeTakeFirst();
						inviteData = {
							firstName: result.first_name,
							lastName: result.last_name,
							email: result.email,
							dateOfBirth: dayjs(result.date_of_birth).toDate(),
							phoneNumber: result.phone_number,
						};
					}

					console.log(`Processing invitation for ${inviteData.email}`);
					// Calculate unified expiration date (7 days from now)
					const expiresAt = dayjs().add(7, "day").toDate();

					// Create a Stripe customer for the invited user
					const customer = await stripe.customers.create({
						name: `${inviteData.firstName} ${inviteData.lastName}`,
						email: inviteData.email,
						metadata: {
							invited_by: user.id,
						},
					});
					console.log(`Created Stripe customer for ${inviteData.email}`);
					console.log(`Creating subscription for ${inviteData.email}`);
					// Create the user directly instead of using inviteUserByEmail
					const { data: authData, error: authError } =
						await supabaseAdmin.auth.admin.createUser({
							email: inviteData.email,
							email_confirm: true,
							user_metadata: {
								first_name: inviteData.firstName,
								last_name: inviteData.lastName,
							},
						});

					if (authError) {
						throw new Error(`Error creating user: ${authError.message}`);
					}
					// Create the invitation record using Kysely
					const invitationId = await createInvitation(
						{
							userId: authData.user.id,
							email: inviteData.email,
							invitationType: "admin",
							expiresAt,
							firstName: inviteData.firstName,
							lastName: inviteData.lastName,
							dateOfBirth: inviteData.dateOfBirth,
							phoneNumber: inviteData.phoneNumber,
						},
						trx,
					);

					const invitationLink = new URL(
						`/members/signup/${invitationId}`,
						Deno.env.get("APP_URL") ?? "http://localhost:5173",
					);
					invitationLink.searchParams.set(
						"dateOfBirth",
						dayjs(inviteData.dateOfBirth).format("YYYY-MM-DD"),
					);
					invitationLink.searchParams.set("email", inviteData.email);

					const payload = JSON.stringify({
						transactionalId: "inviteMember",
						email: inviteData.email,
						dataVariables: {
							firstName: inviteData.firstName,
							lastName: inviteData.lastName,
							invitationLink: invitationLink.toString(),
						},
					});

					await sql`
						select *
						from pgmq.send(
							'email_queue',
							${payload}
								 )
					`.execute(trx);
					// Update user profile with customer ID using Kysely
					await updateUserProfileWithCustomerId(
						authData.user.id,
						customer.id,
						trx,
					);
					console.log(`Updated user profile for ${inviteData.email}`);

					if (!isInviteData(invite)) {
						await trx
							.updateTable("waitlist")
							.set({
								status: "invited",
							})
							.where("id", "=", invite)
							.execute();
					}

					results.push({
						email: inviteData.email,
						success: true,
						invitationId,
					});
					console.log(
						`Successfully processed invitation for ${inviteData.email}`,
					);
				}); // <-- close transaction
			} catch (error) {
				console.error(
					`Failed to process invitation for ${inviteData.email}:`,
					error,
				);
				Sentry.captureException(error);
				const errorMessage =
					error instanceof Error ? error.message : String(error);
				results.push({
					email: inviteData.email,
					success: false,
					error: errorMessage,
				});
			}
		}

		// Store the results in a database or send a notification
		await storeProcessingResults(results, user.id);

		const processingTime = (Date.now() - startTime) / 1000;
		console.log(
			`Completed processing ${invites.length} invitations in ${processingTime}s`,
		);
		// send notification to the user that created the invitation
		const failedInvites = results.filter((r) => !r.success).length;
		const successInvites = results.filter((r) => r.success).length;
		await db
			.insertInto("notifications")
			.values({
				user_id: user.id,
				body:
					failedInvites === 0
						? `Successfully processed ${successInvites} invitations out of ${invites.length}`
						: `Successfully processed ${successInvites} invitations out of ${invites.length}, failed to process ${failedInvites} invitations`,
			})
			.execute();
		return results;
	} catch (error) {
		Sentry.captureException(error);
		const errorMessage = error instanceof Error ? error.message : String(error);
		console.error(`Error in background processing: ${errorMessage}`);
		throw error;
	}
}

/**
 * Store the processing results in the database
 */
async function storeProcessingResults(results: InviteResult[], userId: string) {
	try {
		const successCount = results.filter((r) => r.success).length;
		const failureCount = results.length - successCount;

		// Store the processing summary in the database
		await db
			.insertInto("invitation_processing_logs")
			.values({
				user_id: userId,
				total_count: results.length,
				success_count: successCount,
				failure_count: failureCount,
				results: JSON.stringify(results),
				created_at: new Date().toISOString(),
			})
			.execute();

		console.log(
			`Stored processing results: ${successCount} successful, ${failureCount} failed`,
		);
	} catch (error) {
		Sentry.captureException(error);
		console.error("Failed to store processing results:", error);
	}
}

// Add event listener for beforeUnload to handle graceful shutdown
addEventListener("beforeunload", (event) => {
	console.log("Function is about to be terminated:", event);
	// Perform any cleanup if needed
});

serve(async (req: Request) => {
	try {
		if (req.method === "OPTIONS") {
			return new Response("ok", { headers: corsHeaders });
		}
		if (req.method !== "POST") {
			return new Response(JSON.stringify({ error: "Method not allowed" }), {
				status: 405,
				headers: { "Content-Type": "application/json", ...corsHeaders },
			});
		}
		// Initialize Supabase client with anon key for authentication
		const supabaseClient = createClient(
			Deno.env.get("SUPABASE_URL") ?? "",
			Deno.env.get("SUPABASE_ANON_KEY") ?? "",
		);

		// Get the authorization header and validate the token
		const authHeader = req.headers.get("Authorization");
		if (!authHeader) {
			return new Response(
				JSON.stringify({ error: "Missing Authorization header" }),
				{
					status: 401,
					headers: { "Content-Type": "application/json", ...corsHeaders },
				},
			);
		}

		const token = authHeader.replace("Bearer ", "");
		const { data: userData, error: authError } =
			await supabaseClient.auth.getUser(token);

		if (authError || !userData?.user) {
			return new Response(
				JSON.stringify({ error: "Unauthorized", details: authError?.message }),
				{
					status: 403,
					headers: { "Content-Type": "application/json", ...corsHeaders },
				},
			);
		}

		// Initialize Supabase Admin client
		const supabaseAdmin: ReturnType<typeof createClient> = createClient(
			Deno.env.get("SUPABASE_URL") ?? "",
			Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
		);

		// Parse JSON payload from the request
		const payload = (await req.json()) as { invites: InviteData[] } | string[];

		// Validate user permissions (only admins, presidents, committee coordinators)
		const roles = await getRolesFromSession(token);
		const userRoles = new Set(roles);

		const ALLOWED_ROLES = new Set([
			"admin",
			"president",
			"committee_coordinator",
		]);
		const hasPermission = [...userRoles].some(
			(role) => typeof role === "string" && ALLOWED_ROLES.has(role),
		);

		if (!hasPermission) {
			return new Response(
				JSON.stringify({
					error: "Insufficient permissions to create invitations",
				}),
				{
					status: 403,
					headers: { "Content-Type": "application/json", ...corsHeaders },
				},
			);
		}

		// Get price IDs for immediate validation
		const priceIds = await getPriceIds();

		// Create a background task to process invitations
		const processingPromise = processInvitations(
			Array.isArray(payload) ? payload : payload.invites,
			userData.user,
			supabaseAdmin,
			priceIds,
		);

		// Use waitUntil to keep the function running in the background
		EdgeRuntime.waitUntil(processingPromise);

		// Return an immediate response to the client
		return new Response(
			JSON.stringify({
				message: "Invitations are being processed in the background",
			}),
			{ headers: { "Content-Type": "application/json", ...corsHeaders } },
		);
	} catch (error) {
		Sentry.captureException(error);
		const errorMessage = error instanceof Error ? error.message : String(error);
		return new Response(JSON.stringify({ error: errorMessage }), {
			status: 500,
			headers: { "Content-Type": "application/json", ...corsHeaders },
		});
	}
});
