// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

import Stripe from "stripe";
import dayjs from "npm:dayjs";
import { db, sql } from "../_shared/db.ts";
import { corsHeaders } from "../_shared/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
	apiVersion: "2025-09-30.clover",
	maxNetworkRetries: 3,
	timeout: 30 * 1000,
	httpClient: Stripe.createFetchHttpClient(),
});

const allowedEvents: Stripe.Event.Type[] = [
	"checkout.session.completed",
	"charge.succeeded",
	"charge.expired",
	"charge.refunded",
	"customer.subscription.created",
	"customer.subscription.updated",
	"customer.subscription.deleted",
	"customer.subscription.paused",
	"customer.subscription.resumed",
	"customer.subscription.pending_update_applied",
	"customer.subscription.pending_update_expired",
	"customer.subscription.trial_will_end",
	"invoice.paid",
	"invoice.payment_failed",
	"invoice.payment_action_required",
	"invoice.upcoming",
	"invoice.marked_uncollectible",
	"invoice.payment_succeeded",
	"payment_intent.succeeded",
	"payment_intent.payment_failed",
	"payment_intent.canceled",
];

const WORKSHOP_REGISTRATION_TRANSACTIONAL_ID = "workshopRegistration";
const WORKSHOP_REGISTRATION_ERROR_TRANSACTIONAL_ID =
	"workshopRegistrationError";
const DEFAULT_WORKSHOP_EMAIL_VARIABLES: Record<string, string> = {
	name: "Workshop",
	date: "TBC",
	location: "TBC",
};
const WORKSHOP_REGISTRATION_TECHNICAL_ERROR_MESSAGE =
	"Registration could not be completed due to technical reasons.";

class WorkshopRegistrationUserError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "WorkshopRegistrationUserError";
	}
}

function getWorkshopRegistrationErrorMessage(error: unknown): string {
	if (error instanceof WorkshopRegistrationUserError) {
		return error.message;
	}

	return WORKSHOP_REGISTRATION_TECHNICAL_ERROR_MESSAGE;
}

type DbTransaction = Parameters<
	Parameters<ReturnType<typeof db.transaction>["execute"]>[0]
>[0];

async function setUserInactive(customerId: string) {
	await db
		.updateTable("user_profiles")
		.set({ is_active: false })
		.where("customer_id", "=", customerId)
		.execute()
		.then(console.log);
}

async function queueWorkshopRegistrationEmail(input: {
	transactionalId:
		| typeof WORKSHOP_REGISTRATION_TRANSACTIONAL_ID
		| typeof WORKSHOP_REGISTRATION_ERROR_TRANSACTIONAL_ID;
	email: string;
	dataVariables: Record<string, string>;
}) {
	const payload = {
		transactionalId: input.transactionalId,
		email: input.email,
		dataVariables: input.dataVariables,
	};

	await sql`
		SELECT pgmq.send('email_queue', ${JSON.stringify(payload)}::jsonb)
	`.execute(db);
}

async function loadExternalCheckoutContext(input: {
	workshopId: string;
	session: Stripe.Checkout.Session;
}) {
	const { workshopId, session } = input;
	const checkoutSession = session;

	if (
		checkoutSession.status !== "complete" ||
		checkoutSession.payment_status !== "paid"
	) {
		throw new Error("Payment has not been completed");
	}

	const metadata = checkoutSession.metadata ?? {};
	if (
		metadata.type !== "workshop_registration" ||
		metadata.actor_type !== "external" ||
		metadata.workshop_id !== workshopId
	) {
		throw new Error("Checkout session does not match the registration request");
	}

	const customerEmail =
		checkoutSession.customer_details?.email ?? checkoutSession.customer_email;
	const customerName = checkoutSession.customer_details?.name?.trim() ?? "";
	const customerPhone = checkoutSession.customer_details?.phone ?? null;

	if (!customerEmail || customerName.length === 0) {
		throw new Error("Missing customer details from checkout session");
	}

	const paymentIntentId =
		typeof checkoutSession.payment_intent === "string"
			? checkoutSession.payment_intent
			: checkoutSession.payment_intent?.id;

	if (paymentIntentId) {
		try {
			await stripe.paymentIntents.update(paymentIntentId, {
				receipt_email: customerEmail,
			});
		} catch (error) {
			console.warn("Failed to set receipt email on payment intent", {
				paymentIntentId,
				checkoutSessionId: checkoutSession.id,
				workshopId,
				error: error instanceof Error ? error.message : String(error),
			});
		}
	}

	if (checkoutSession.amount_total === null) {
		throw new Error("Checkout session amount is missing");
	}

	const [firstName = "", ...lastNameParts] = customerName.split(/\s+/);
	if (firstName.length === 0) {
		throw new Error("Missing customer name from checkout session");
	}
	const lastName = lastNameParts.join(" ");

	return {
		checkoutSession,
		customerEmail,
		firstName,
		lastName,
		customerPhone,
	};
}

async function completeExternalRegistrationFromCheckoutSessionTx(
	trx: DbTransaction,
	input: {
		workshopId: string;
		workshop: {
			status: string | null;
			is_public: boolean | null;
			max_capacity: number;
			price_non_member: number | null;
		};
		checkoutSession: Stripe.Checkout.Session;
		customerEmail: string;
		firstName: string;
		lastName: string;
		customerPhone: string | null;
	},
) {
	const {
		workshopId,
		workshop,
		checkoutSession,
		customerEmail,
		firstName,
		lastName,
		customerPhone,
	} = input;

	if (
		workshop.status !== "published" ||
		!workshop.is_public ||
		workshop.price_non_member === null ||
		workshop.price_non_member < 0
	) {
		throw new Error("Workshop not found or not available for registration");
	}

	if (checkoutSession.amount_total !== Number(workshop.price_non_member)) {
		throw new Error("Checkout amount does not match workshop price");
	}

	const existingByCheckoutSession = await trx
		.selectFrom("club_activity_registrations")
		.selectAll()
		.where("stripe_checkout_session_id", "=", checkoutSession.id)
		.executeTakeFirst();

	if (existingByCheckoutSession) {
		return existingByCheckoutSession;
	}

	const normalizedEmail = customerEmail.trim().toLowerCase();
	const existingExternalUser = await trx
		.selectFrom("external_users")
		.select(["id"])
		.where("email", "=", normalizedEmail)
		.executeTakeFirst();

	let externalUserId: string;
	if (existingExternalUser) {
		await trx
			.updateTable("external_users")
			.set({
				first_name: firstName,
				last_name: lastName,
				phone_number: customerPhone,
				updated_at: dayjs().toISOString(),
			})
			.where("id", "=", existingExternalUser.id)
			.execute();

		externalUserId = existingExternalUser.id;
	} else {
		const createdExternalUser = await trx
			.insertInto("external_users")
			.values({
				email: normalizedEmail,
				first_name: firstName,
				last_name: lastName,
				phone_number: customerPhone,
			})
			.returning(["id"])
			.executeTakeFirstOrThrow();

		externalUserId = createdExternalUser.id;
	}

	const existingRegistration = await trx
		.selectFrom("club_activity_registrations")
		.selectAll()
		.where("club_activity_id", "=", workshopId)
		.where("external_user_id", "=", externalUserId)
		.where("status", "in", ["pending", "confirmed"])
		.executeTakeFirst();

	if (existingRegistration) {
		if (
			existingRegistration.stripe_checkout_session_id !== checkoutSession.id
		) {
			throw new WorkshopRegistrationUserError(
				"this email already being registered for this workshop",
			);
		}
		return existingRegistration;
	}

	const registrationCount = await trx
		.selectFrom("club_activity_registrations")
		.select((eb) => eb.fn.count("id").as("count"))
		.where("club_activity_id", "=", workshopId)
		.where("status", "in", ["pending", "confirmed"])
		.executeTakeFirst();

	if (Number(registrationCount?.count ?? 0) >= workshop.max_capacity) {
		const paymentIntent =
			typeof checkoutSession.payment_intent === "string"
				? null
				: checkoutSession.payment_intent;
		const latestCharge = paymentIntent?.latest_charge;
		const chargeId =
			typeof latestCharge === "string" ? latestCharge : latestCharge?.id;

		if (chargeId) {
			await stripe.refunds.create({
				charge: chargeId,
				reason: "duplicate",
			});
		}

		throw new WorkshopRegistrationUserError(
			"the workshop reaching maximum capacity",
		);
	}

	const now = dayjs().toISOString();

	return trx
		.insertInto("club_activity_registrations")
		.values({
			club_activity_id: workshopId,
			external_user_id: externalUserId,
			member_user_id: null,
			status: "confirmed",
			stripe_checkout_session_id: checkoutSession.id,
			amount_paid: checkoutSession.amount_total,
			currency: checkoutSession.currency ?? "eur",
			confirmed_at: now,
			registered_at: now,
		})
		.returningAll()
		.executeTakeFirstOrThrow();
}

async function handleWorkshopCheckoutCompleted(
	session: Stripe.Checkout.Session,
) {
	const metadata = session.metadata ?? {};
	if (
		metadata.type !== "workshop_registration" ||
		metadata.actor_type !== "external" ||
		!metadata.workshop_id
	) {
		console.log(
			`Ignoring checkout.session.completed ${session.id} - not an external workshop registration session`,
		);
		return;
	}

	const workshopId = metadata.workshop_id;

	const fallbackRecipientEmail =
		session.customer_details?.email ?? session.customer_email ?? null;

	let dataVariables: Record<string, string> = {
		...DEFAULT_WORKSHOP_EMAIL_VARIABLES,
	};

	try {
		const checkoutContext = await loadExternalCheckoutContext({
			workshopId,
			session,
		});

		const { recipientEmail, emailDataVariables } = await db
			.transaction()
			.execute(async (trx) => {
				const workshop = await trx
					.selectFrom("club_activities")
					.select([
						"title",
						"start_date",
						"location",
						"status",
						"is_public",
						"max_capacity",
						"price_non_member",
					])
					.where("id", "=", workshopId)
					.executeTakeFirst();

				if (!workshop) {
					throw new Error(
						`Workshop not found for checkout session ${session.id}`,
					);
				}

				const registration =
					await completeExternalRegistrationFromCheckoutSessionTx(trx, {
						workshopId,
						workshop,
						...checkoutContext,
					});

				const registrationRecipient = await trx
					.selectFrom("club_activity_registrations as car")
					.innerJoin("external_users as eu", "car.external_user_id", "eu.id")
					.select(["eu.email as email"])
					.where("car.id", "=", registration.id)
					.executeTakeFirst();

				return {
					recipientEmail:
						registrationRecipient?.email ?? fallbackRecipientEmail,
					emailDataVariables: {
						name: workshop.title,
						date: dayjs(workshop.start_date).format("DD MMM YYYY HH:mm"),
						location: workshop.location ?? "TBC",
					},
				};
			});

		if (!recipientEmail) {
			throw new Error(
				`Registration email not found for checkout session ${session.id}`,
			);
		}

		dataVariables = emailDataVariables;

		await queueWorkshopRegistrationEmail({
			transactionalId: WORKSHOP_REGISTRATION_TRANSACTIONAL_ID,
			email: recipientEmail,
			dataVariables: emailDataVariables,
		});

		console.log(
			`Queued workshop registration success email for checkout session: ${session.id}`,
		);
	} catch (error) {
		const recipientEmail = fallbackRecipientEmail;

		if (!recipientEmail) {
			console.error(
				`Unable to queue workshop registration error email for checkout session ${session.id}: recipient email unavailable`,
				error,
			);
			return;
		}

		await queueWorkshopRegistrationEmail({
			transactionalId: WORKSHOP_REGISTRATION_ERROR_TRANSACTIONAL_ID,
			email: recipientEmail,
			dataVariables: {
				...dataVariables,
				error: getWorkshopRegistrationErrorMessage(error),
			},
		});

		console.error(
			`Queued workshop registration error email for checkout session: ${session.id}`,
			error,
		);
	}
}

async function handleWorkshopCheckoutExpired(session: Stripe.Charge) {
	try {
		if (session.metadata?.workshop_id) {
			// Mark any pending registrations as cancelled
			await db
				.updateTable("club_activity_registrations")
				.set({
					status: "cancelled",
					cancelled_at: dayjs().toISOString(),
				})
				.where("stripe_checkout_session_id", "=", session.id)
				.where("status", "=", "pending")
				.execute();

			console.log(
				`Workshop registration cancelled for expired checkout session: ${session.id}`,
			);
		}
	} catch (error) {
		console.error("Error handling workshop checkout expiration:", error);
		throw error;
	}
}

async function handleChargeRefunded(charge: Stripe.Charge) {
	try {
		// Get all refunds for this charge
		const refunds = await stripe.refunds.list({
			charge: charge.id,
			limit: 100,
		});

		for (const refund of refunds.data) {
			// Update refund status based on Stripe refund status
			let status: "completed" | "failed" | "processing";
			let completed_at: Date | null = null;

			switch (refund.status) {
				case "succeeded":
					status = "completed";
					completed_at = new Date();
					break;
				case "failed":
					status = "failed";
					break;
				case "pending":
				case "requires_action":
					status = "processing";
					break;
				default:
					status = "processing";
			}

			// Update refund status in database
			const updateData: { status: string; completed_at?: string } = { status };
			if (completed_at) {
				updateData.completed_at = completed_at.toISOString();
			}

			await db
				.updateTable("club_activity_refunds")
				.set(updateData)
				.where("stripe_refund_id", "=", refund.id)
				.execute();

			console.log(
				`Refund status updated: ${refund.id} -> ${status} for charge: ${charge.id}`,
			);
		}
	} catch (error) {
		console.error("Error handling charge refund:", error);
		throw error;
	}
}

async function syncStripeDataToKV(customerId: string) {
	try {
		// Fetch latest subscription data from Stripe
		const subscriptions = await stripe.subscriptions.list({
			customer: customerId,
			limit: 2, // User can have at most 2 subscriptions
			status: "all",
			expand: ["data.latest_invoice"],
		});

		// Find the standard membership subscription
		const standardMembershipSub = subscriptions.data.find((sub) =>
			sub.items.data.some(
				(item) => item.price.lookup_key === "standard_membership_fee",
			),
		);

		// If no standard membership or it's canceled/expired/unpaid, mark user as inactive
		if (
			!standardMembershipSub ||
			["canceled", "incomplete_expired", "unpaid"].includes(
				standardMembershipSub.status,
			)
		) {
			return setUserInactive(customerId);
		}

		// Handle paused subscriptions - keep user active, update pause status in DB
		if (standardMembershipSub.pause_collection !== null) {
			const resumeDate = standardMembershipSub.pause_collection?.resumes_at
				? dayjs.unix(standardMembershipSub.pause_collection.resumes_at).toDate()
				: null;

			// Update pause status in database
			await db
				.updateTable("member_profiles")
				.set({ subscription_paused_until: resumeDate })
				.where(
					"user_profile_id",
					"in",
					db
						.selectFrom("user_profiles")
						.select("id")
						.where("customer_id", "=", customerId),
				)
				.execute();

			console.log(
				`Subscription paused for customer: ${customerId} until ${resumeDate}`,
			);
			return Promise.resolve();
		}

		if (standardMembershipSub.status === "active") {
			await db.transaction().execute((trx) => {
				return Promise.all([
					trx
						.updateTable("member_profiles")
						.set({
							subscription_paused_until: null,
							last_payment_date: dayjs
								.unix(standardMembershipSub.start_date)
								.toDate(),
							membership_end_date: standardMembershipSub.ended_at
								? dayjs.unix(standardMembershipSub.ended_at).toDate()
								: null,
						})
						.where(
							"user_profile_id",
							"in",
							db
								.selectFrom("user_profiles")
								.select("id")
								.where("customer_id", "=", customerId),
						)
						.execute(),
					trx
						.updateTable("user_profiles")
						.set({ is_active: true })
						.where("customer_id", "=", customerId)
						.execute(),
				]);
			});
		}
		return Promise.resolve();
	} catch (error) {
		console.error("Error syncing Stripe data:", error);
		throw error;
	}
}

addEventListener("beforeUnload", (ev) => {
	console.log("task terminated because", ev);
});

Deno.serve(async (req) => {
	if (req.method === "OPTIONS") {
		return new Response("ok", { headers: corsHeaders });
	}

	try {
		const signature = req.headers.get("stripe-signature");
		if (!signature) {
			throw new Error("No stripe signature found");
		}

		const body = await req.text();
		const event = await stripe.webhooks.constructEventAsync(
			body,
			signature,
			Deno.env.get("STRIPE_WEBHOOK_SIGNING_SECRET") ?? "",
		);

		// Check if event type is in allowed events
		if (!allowedEvents.includes(event.type as Stripe.Event.Type)) {
			console.log(`Ignoring unhandled event type: ${event.type}`);
			return new Response(JSON.stringify({ received: true }), {
				headers: { ...corsHeaders, "Content-Type": "application/json" },
				status: 200,
			});
		}

		// Handle workshop registration checkout sessions
		if (event.type === "checkout.session.completed") {
			const session = event.data.object as Stripe.Checkout.Session;
			EdgeRuntime.waitUntil(handleWorkshopCheckoutCompleted(session));
		} else if (event.type === "charge.expired") {
			const session = event.data.object as Stripe.Charge;
			if (session.metadata?.workshop_id) {
				EdgeRuntime.waitUntil(handleWorkshopCheckoutExpired(session));
			}
		} else if (event.type === "charge.refunded") {
			const charge = event.data.object as Stripe.Charge;
			EdgeRuntime.waitUntil(handleChargeRefunded(charge));
		}

		// Handle subscription-related events
		const eventObject = event?.data?.object as { customer?: string };
		if (eventObject.customer) {
			// Sync stripe data for subscription events
			EdgeRuntime.waitUntil(syncStripeDataToKV(eventObject.customer));
		}

		return new Response(JSON.stringify({ success: true }), {
			headers: { ...corsHeaders, "Content-Type": "application/json" },
			status: 200,
		});
	} catch (err) {
		console.error("Error processing webhook:", err);
		return new Response(JSON.stringify({ error: (err as Error)?.message }), {
			headers: { ...corsHeaders, "Content-Type": "application/json" },
			status: 400,
		});
	}
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/stripe-webhooks' \
    --header 'Stripe-Signature: YOUR_SIGNATURE' \
    --header 'Content-Type: application/json' \
    --data-raw '{
      "type": "payment_intent.succeeded",
      "data": {
        "object": {
          "id": "pi_123",
          "customer": "cus_123"
        }
      }
    }'
*/
