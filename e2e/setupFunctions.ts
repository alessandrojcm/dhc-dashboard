import { faker } from "@faker-js/faker/locale/en_IE";
import { createClient } from "@supabase/supabase-js";
import "dotenv/config";
import { createSeedClient } from "@snaplet/seed";
import dayjs from "dayjs";
import stripe from "stripe";
import type { Database } from "../src/database.types";
import {
	ANNUAL_FEE_LOOKUP,
	MEMBERSHIP_FEE_LOOKUP_NAME,
} from "../src/lib/server/constants";

export const stripeClient = new stripe(process.env.STRIPE_SECRET_KEY || "", {
	apiVersion: "2025-10-29.clover",
});

export function getSupabaseServiceClient() {
	const supabaseUrl = process.env.PUBLIC_SUPABASE_URL;
	const serviceRoleKey = process.env.SERVICE_ROLE_KEY;
	if (!supabaseUrl || !serviceRoleKey) {
		throw new Error(
			"Missing SUPABASE_URL or SERVICE_ROLE_KEY in environment variables",
		);
	}
	return createClient<Database>(supabaseUrl, serviceRoleKey);
}

const defaultValues = {
	addWaitlist: true,
	addSupabaseId: true,
	setWaitlistNotCompleted: false,
};

export async function createMember({
	email = faker.internet.email().toLowerCase(),
	roles = new Set(["member"]),
	createSubscription = false,
}: {
	email: string;
	roles?: Set<Database["public"]["Enums"]["role_type"]>;
	createSubscription?: boolean;
}) {
	const supabaseServiceClient = getSupabaseServiceClient();
	const testData = {
		first_name: faker.person.firstName(),
		last_name: faker.person.lastName(),
		email: email,
		date_of_birth: faker.date.birthdate({ min: 16, max: 65, mode: "age" }),
		pronouns: faker.helpers.arrayElement(["he/him", "she/her", "they/them"]),
		gender: faker.helpers.arrayElement([
			"man (cis)",
			"woman (cis)",
			"non-binary",
		] as Database["public"]["Enums"]["gender"][]),
		weapon: faker.helpers.arrayElement(["longsword", "rapier", "sabre"]),
		phone_number: faker.phone.number({ style: "international" }),
		next_of_kin: {
			name: faker.person.fullName(),
			phone_number: faker.phone.number({ style: "international" }),
		},
		medical_conditions: faker.helpers.arrayElement([
			"None",
			"Asthma",
			"Previous knee injury",
		]),
	};

	async function cleanUp() {
		// We need to create another client because when we use verifyOtp, we are effectively
		// logging as the user we are verifying the token for, hence we lose the service role privileges
		const client = getSupabaseServiceClient();
		if (waitlisEntry?.data?.profile_id) {
			await client
				.from("member_profiles")
				.delete()
				.eq("user_profile_id", waitlisEntry.data.profile_id)
				.throwOnError();
			await client
				.from("user_profiles")
				.delete()
				.eq("id", waitlisEntry.data.profile_id)
				.throwOnError();
		}
		if (inviteLink.data.user?.id) {
			await client.auth.admin.deleteUser(inviteLink.data.user.id);
		}
		if (cleanUpFn) {
			await cleanUpFn();
		}
		return Promise.resolve();
	}

	const waitlisEntry = await supabaseServiceClient
		.rpc("insert_waitlist_entry", {
			first_name: testData.first_name,
			last_name: testData.last_name,
			email: testData.email,
			date_of_birth: testData.date_of_birth.toISOString(),
			phone_number: testData.phone_number.toString(),
			pronouns: testData.pronouns,
			gender: testData.gender as Database["public"]["Enums"]["gender"],
			medical_conditions: testData.medical_conditions,
		})
		.single();
	if (waitlisEntry.error) {
		throw new Error(waitlisEntry.error.message);
	}
	const inviteLink = await supabaseServiceClient.auth.admin.createUser({
		email: testData.email,
		password: "password",
		email_confirm: true,
	});
	if (inviteLink.error) {
		throw new Error(inviteLink.error.message);
	}
	let cleanUpFn: () => Promise<void>;
	let customerId: string | null = null;
	if (createSubscription) {
		const { cleanUp, ...rest } = await createStripeCustomerWithSubscription(
			testData.email,
		);
		customerId = rest.customerId;
		cleanUpFn = cleanUp;
	}

	await supabaseServiceClient
		.from("user_profiles")
		.update({
			supabase_user_id: inviteLink.data.user.id,
			waitlist_id: waitlisEntry.data.waitlist_id,
			customer_id: customerId,
		})
		.eq("id", waitlisEntry.data.profile_id)
		.select()
		.throwOnError();

	// Run these independent operations in parallel
	await Promise.all([
		supabaseServiceClient
			.from("user_roles")
			.insert(
				Array.from(roles)
					.filter((role) => role !== "member")
					.map((role) => ({
						user_id: inviteLink.data.user.id,
						role,
					})),
			)
			.throwOnError(),
		// Update user metadata to include roles in JWT token
		supabaseServiceClient.auth.admin.updateUserById(inviteLink.data.user.id, {
			app_metadata: {
				roles: Array.from(roles),
			},
		}),
		supabaseServiceClient
			.from("waitlist")
			.update({
				status: "completed",
			})
			.eq("email", testData.email)
			.throwOnError(),
	]);

	const { data } = await supabaseServiceClient
		.rpc("complete_member_registration", {
			v_user_id: inviteLink.data.user?.id || "",
			p_next_of_kin_name: testData.next_of_kin.name,
			p_next_of_kin_phone: testData.next_of_kin.phone_number,
			p_insurance_form_submitted: true,
		})
		.throwOnError();
	const verifyOtp = await supabaseServiceClient.auth.signInWithPassword({
		email: testData.email,
		password: "password",
	});
	if (verifyOtp.error) {
		throw new Error(verifyOtp.error.message);
	}
	await supabaseServiceClient.auth.signOut();
	return Promise.resolve({
		...testData,
		waitlistId: waitlisEntry.data.waitlist_id,
		profileId: waitlisEntry.data.profile_id,
		session: verifyOtp.data.session,
		memberId: data,
		userId: verifyOtp.data.user?.id,
		cleanUp,
	});
}

export async function createStripeCustomerWithSubscription(email: string) {
	// Create a customer
	const customer = await stripeClient.customers.create({
		email,
		metadata: {
			source: "test",
		},
	});

	// Create a SEPA Direct Debit payment method
	const paymentMethod = await stripeClient.paymentMethods.create({
		type: "sepa_debit",
		sepa_debit: {
			iban: "IE29AIBK93115212345678",
		},
		billing_details: {
			email,
			name: "Test User",
		},
	});

	// Attach the payment method to the customer
	await stripeClient.paymentMethods.attach(paymentMethod.id, {
		customer: customer.id,
	});

	// Set as default payment method
	await stripeClient.customers.update(customer.id, {
		invoice_settings: {
			default_payment_method: paymentMethod.id,
		},
	});

	// Get the price ID for the membership fee
	let prices = await stripeClient.prices.search({
		query: `lookup_key:'${MEMBERSHIP_FEE_LOOKUP_NAME}'`,
	});

	if (!prices.data.length) {
		throw new Error(
			`No price found with lookup key: ${MEMBERSHIP_FEE_LOOKUP_NAME}`,
		);
	}

	// Create the subscription
	let subscription = await stripeClient.subscriptions.create({
		customer: customer.id,
		items: [{ price: prices.data[0].id }],
		default_payment_method: paymentMethod.id,
		expand: ["latest_invoice.payments"],
	});

	// Get the price ID for the membership fee
	prices = await stripeClient.prices.search({
		query: `lookup_key:'${ANNUAL_FEE_LOOKUP}'`,
	});

	if (!prices.data.length) {
		throw new Error(`No price found with lookup key: ${ANNUAL_FEE_LOOKUP}`);
	}

	// Create the subscription
	subscription = await stripeClient.subscriptions.create({
		customer: customer.id,
		items: [{ price: prices.data[0].id }],
		default_payment_method: paymentMethod.id,
		expand: ["latest_invoice.payments"],
	});

	return {
		customerId: customer.id,
		subscriptionId: subscription.id,
		paymentMethodId: paymentMethod.id,
		async cleanUp() {
			await stripeClient.customers.del(customer.id);
		},
	};
}

export async function createWorkshop({
	title,
	description = "",
	location,
	start_date,
	end_date,
	max_capacity,
	price_member,
	price_non_member,
	is_public = false,
	refund_days = null,
	created_by,
	status = "planned",
}: {
	title: string;
	description?: string;
	location: string;
	start_date: Date;
	end_date: Date;
	max_capacity: number;
	price_member: number;
	price_non_member?: number;
	is_public?: boolean;
	refund_days?: number | null;
	created_by: string;
	status?: Database["public"]["Enums"]["club_activity_status"];
}) {
	const supabaseServiceClient = getSupabaseServiceClient();

	const { data } = await supabaseServiceClient
		.from("club_activities")
		.insert({
			title,
			description,
			location,
			start_date: start_date.toISOString(),
			end_date: end_date.toISOString(),
			max_capacity,
			price_member,
			price_non_member: price_non_member ?? price_member,
			is_public,
			refund_days,
			created_by,
			status,
		})
		.select()
		.single()
		.throwOnError();

	const workshop = data!;
	const workshopId = workshop.id;

	async function cleanUp() {
		const client = getSupabaseServiceClient();
		await client
			.from("club_activities")
			.delete()
			.eq("id", workshopId)
			.throwOnError();
	}

	return {
		...data,
		cleanUp,
	};
}

export function createUniqueEmail(
	prefix: string,
	index?: number,
	retry?: number,
) {
	const timestamp = Date.now();
	const randomSuffix = Math.random().toString(36).substring(2, 7);
	const indexPart = index === undefined ? "" : `-${index}`;
	const retryPart = retry === undefined ? "" : `-r${retry}`;
	return `${prefix}-${timestamp}${indexPart}-${randomSuffix}${retryPart}@test.com`;
}

export async function setupInvitedUser(
	params: Partial<{
		addInvitation: boolean;
		addSupabaseId: boolean;
		email: string;
		invitationStatus: Database["public"]["Enums"]["invitation_status"];
		token: string;
		useFakeCustomerId?: boolean;
	}> = {},
) {
	const defaultInviteValues = {
		addInvitation: true,
		addSupabaseId: true,
		invitationStatus:
			"pending" as Database["public"]["Enums"]["invitation_status"],
		useFakeCustomerId: false,
	};
	const overrides = {
		...defaultInviteValues,
		...params,
		email: params.email || faker.internet.email().toLowerCase(),
	};

	const { email, useFakeCustomerId } = overrides;
	const supabaseServiceClient = getSupabaseServiceClient();

	// Create test user data
	const testData = {
		first_name: faker.person.firstName(),
		last_name: faker.person.lastName(),
		email,
		date_of_birth: faker.date.birthdate({ min: 16, max: 65, mode: "age" }),
		pronouns: faker.helpers.arrayElement(["he/him", "she/her", "they/them"]),
		gender: faker.helpers.arrayElement([
			"man (cis)",
			"woman (cis)",
			"non-binary",
		] as Database["public"]["Enums"]["gender"][]),
		weapon: faker.helpers.arrayElement(["longsword", "rapier", "sabre"]),
		phone_number: faker.phone.number({ style: "international" }),
		next_of_kin: {
			name: faker.person.fullName(),
			phone_number: faker.phone.number({ style: "international" }),
		},
		medical_conditions: faker.helpers.arrayElement([
			"None",
			"Asthma",
			"Previous knee injury",
		]),
	};

	// Create a user in Supabase Auth
	const { data: authData, error: authError } =
		await supabaseServiceClient.auth.admin.createUser({
			email: testData.email,
			password: "password",
			email_confirm: true,
			user_metadata: {
				first_name: testData.first_name,
				last_name: testData.last_name,
			},
		});

	if (authError) {
		throw new Error(`Error creating user: ${authError.message}`);
	}
	let customerId: string | null = null;

	if (!useFakeCustomerId) {
		// Create a Stripe customer for the invited user
		const customer = await stripeClient.customers.create({
			name: `${testData.first_name} ${testData.last_name}`,
			email: testData.email,
			metadata: {
				invited_by: "e2e-test",
			},
		});
		customerId = customer.id;
	} else {
		customerId = crypto.randomUUID();
	}

	// Calculate expiration date (24 hours from now)
	const expiresAt = new Date();
	if (overrides.invitationStatus !== "expired") {
		expiresAt.setHours(expiresAt.getHours() + 24);
	}

	// Create invitation using the stored procedure
	// This will also create the user profile
	const { error: invitationError, data: invitationData } =
		await supabaseServiceClient.rpc("create_invitation", {
			v_user_id: authData.user.id,
			p_email: testData.email,
			p_first_name: testData.first_name,
			p_last_name: testData.last_name,
			p_date_of_birth: testData.date_of_birth.toISOString(),
			p_phone_number: testData.phone_number,
			p_invitation_type: "admin",
			p_waitlist_id: undefined,
			p_expires_at: expiresAt.toISOString(),
			p_metadata: {},
		});

	if (invitationError) {
		throw new Error(`Error creating invitation: ${invitationError.message}`);
	}

	// Update user profile with customer ID directly
	const { error: profileError } = await supabaseServiceClient
		.from("user_profiles")
		.update({ customer_id: customerId })
		.eq("supabase_user_id", authData.user.id);

	if (profileError) {
		throw new Error(`Error updating user profile: ${profileError.message}`);
	}

	// User profile already has customer_id from the upsert operation above

	if (!useFakeCustomerId) {
		// Get price IDs for subscriptions
		const [monthlyPrices, annualPrices] = await Promise.all([
			stripeClient.prices.search({
				query: `lookup_key:'${MEMBERSHIP_FEE_LOOKUP_NAME}'`,
			}),
			stripeClient.prices.search({
				query: `lookup_key:'${ANNUAL_FEE_LOOKUP}'`,
			}),
		]);

		if (!monthlyPrices.data.length || !annualPrices.data.length) {
			throw new Error("Failed to retrieve price IDs from Stripe");
		}

		// Create new subscriptions using Promise.all like in the Deno function
		await Promise.all([
			stripeClient.subscriptions.create({
				customer: customerId,
				items: [{ price: monthlyPrices.data[0].id }],
				billing_cycle_anchor_config: {
					day_of_month: 1,
				},
				payment_behavior: "default_incomplete",
				payment_settings: {
					payment_method_types: ["sepa_debit"],
				},
				expand: ["latest_invoice.payments"],
				collection_method: "charge_automatically",
			}),
			stripeClient.subscriptions.create({
				customer: customerId,
				items: [{ price: annualPrices.data[0].id }],
				payment_behavior: "default_incomplete",
				payment_settings: {
					payment_method_types: ["sepa_debit"],
				},
				billing_cycle_anchor_config: {
					month: 1,
					day_of_month: 7,
				},
				expand: ["latest_invoice.payments"],
				collection_method: "charge_automatically",
			}),
		]);
	}

	// Cleanup function
	async function cleanUp() {
		const client = await createSeedClient();
		await client.$resetDatabase(["public.user_profiles", "public.invitations"]);
	}

	return Promise.resolve({
		...testData,
		date_of_birth: dayjs(testData.date_of_birth.toISOString()),
		invitationId: invitationData,
		token: async () => {
			// Sign in to get access token
			const verifyOtp = await supabaseServiceClient.auth.signInWithPassword({
				email: testData.email,
				password: "password",
			});

			if (verifyOtp.error) {
				throw new Error(verifyOtp.error.message);
			}

			if (!verifyOtp.data.session || !verifyOtp.data.session.access_token) {
				throw new Error("Failed to get access token");
			}

			await supabaseServiceClient.auth.signOut();
			return verifyOtp.data.session.access_token;
		},
		cleanUp,
	});
}
