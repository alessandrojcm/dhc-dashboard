import { faker } from "@faker-js/faker/locale/en_IE";
import type { WorkshopStatus } from "@dhc/api-client";
import { expect, type Page } from "@playwright/test";
import "dotenv/config";
import dayjs from "dayjs";
import stripe from "stripe";
import {
	ANNUAL_FEE_LOOKUP,
	MEMBERSHIP_FEE_LOOKUP_NAME,
} from "../src/lib/server/constants";
import { deleteE2EFixture, seedE2EScenario } from "./e2eApi";
import type { E2ERole } from "./e2eApi";

export const stripeClient = new stripe(process.env.STRIPE_SECRET_KEY || "", {
	apiVersion: "2025-10-29.clover",
});

export async function routeSuccessfulDiscordAcceptance(
	page: Page,
	invitationId: string,
) {
	await page.route(
		`**/members/signup/${invitationId}/discord`,
		async (route) => {
			const response = await route.fetch({ maxRedirects: 0 });
			expect(response.status()).toBe(302);
			const authorizationUrl = new URL(response.headers().location);
			expect(authorizationUrl.origin + authorizationUrl.pathname).toBe(
				"https://discord.example.com/oauth2/authorize",
			);
			expect(authorizationUrl.searchParams.get("redirect_uri")).toBe(
				"http://127.0.0.1:5173/auth/discord/acceptance/callback",
			);
			await route.fulfill({
				response,
				headers: {
					...response.headers(),
					location:
						"http://127.0.0.1:5173/auth/discord/acceptance/callback?state=test-state&code=success",
				},
			});
		},
	);
}

const person = (email: string) => ({
	first_name: faker.person.firstName(),
	last_name: faker.person.lastName(),
	email,
	date_of_birth: faker.date.birthdate({ min: 18, max: 65, mode: "age" }),
	pronouns: faker.helpers.arrayElement(["he/him", "she/her", "they/them"]),
	gender: faker.helpers.arrayElement([
		"man (cis)",
		"woman (cis)",
		"non-binary",
	]),
	weapon: faker.helpers.arrayElement(["longsword", "rapier", "sabre"]),
	phone_number: faker.phone.number({ style: "international" }),
	next_of_kin: {
		name: faker.person.fullName(),
		phone_number: faker.phone.number({ style: "international" }),
	},
	medical_conditions: "None",
});

export async function createMember({
	email = faker.internet.email().toLowerCase(),
	roles = new Set<E2ERole>(["member"]),
	createSubscription = false,
}: {
	email: string;
	roles?: Set<E2ERole>;
	createSubscription?: boolean;
}) {
	const testData = person(email);
	let stripeCleanup: (() => Promise<void>) | undefined;
	let customerId: string | undefined;

	if (createSubscription) {
		const subscription = await createStripeCustomerWithSubscription(email);
		customerId = subscription.customerId;
		stripeCleanup = subscription.cleanUp;
	}

	const seeded = await seedE2EScenario("member", {
		email,
		roles: Array.from(roles),
		firstName: testData.first_name,
		lastName: testData.last_name,
		dateOfBirth: testData.date_of_birth.toISOString(),
		phoneNumber: testData.phone_number,
		pronouns: testData.pronouns,
		gender: testData.gender,
		medicalConditions: testData.medical_conditions,
		customerId,
	});

	return {
		...testData,
		...seeded,
		async cleanUp() {
			await deleteE2EFixture("member", seeded.userId);
			await stripeCleanup?.();
		},
	};
}

export async function setupWaitlistedUser(
	params: Partial<{
		setWaitlistNotCompleted: boolean;
		email: string;
	}> = {},
) {
	const email = params.email ?? faker.internet.email().toLowerCase();
	const testData = person(email);
	const seeded = await seedE2EScenario("waitlist", {
		email,
		firstName: testData.first_name,
		lastName: testData.last_name,
		dateOfBirth: testData.date_of_birth.toISOString(),
		phoneNumber: testData.phone_number,
		pronouns: testData.pronouns,
		gender: testData.gender,
		medicalConditions: testData.medical_conditions,
		status: params.setWaitlistNotCompleted ? "cancelled" : "completed",
	});

	return {
		...testData,
		...seeded,
		async cleanUp() {
			await deleteE2EFixture("waitlist", seeded.waitlistId);
		},
	};
}

export async function setupInvitedUser(
	params: Partial<{
		addInvitation: boolean;
		dateOfBirth: Date;
		email: string;
		invitationStatus: "pending" | "expired" | "accepted" | "revoked";
		token: string;
		useFakeCustomerId: boolean;
	}> = {},
) {
	const email = params.email ?? faker.internet.email().toLowerCase();
	const testData = person(email);
	if (params.dateOfBirth) testData.date_of_birth = params.dateOfBirth;

	if (params.addInvitation === false) {
		return {
			...testData,
			date_of_birth: dayjs(testData.date_of_birth),
			invitationId: "00000000-0000-0000-0000-000000000000",
			async cleanUp() {},
		};
	}

	const seeded = await seedE2EScenario("invitation", {
		email,
		status: params.invitationStatus ?? "pending",
		firstName: testData.first_name,
		lastName: testData.last_name,
		dateOfBirth: testData.date_of_birth.toISOString(),
		phoneNumber: testData.phone_number,
		customerId: params.useFakeCustomerId ? "cus_e2e_fake" : undefined,
	});

	return {
		...testData,
		...seeded,
		date_of_birth: dayjs(seeded.dateOfBirth),
		async token() {
			return params.token ?? "e2e-invitation-token";
		},
		async cleanUp() {
			try {
				await deleteStripeCustomersByEmail(email);
			} finally {
				await deleteE2EFixture("invitation", seeded.invitationId);
			}
		},
	};
}

async function deleteStripeCustomersByEmail(email: string) {
	const customers = await stripeClient.customers.list({ email, limit: 100 });

	for (const customer of customers.data) {
		if (!customer.deleted) {
			await stripeClient.customers.del(customer.id);
		}
	}
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
	status?: WorkshopStatus;
}) {
	const workshop = await seedE2EScenario("workshop", {
		title,
		description,
		location,
		startDate: start_date.toISOString(),
		endDate: end_date.toISOString(),
		maxCapacity: max_capacity,
		priceMember: price_member,
		priceNonMember: price_non_member ?? price_member,
		isPublic: is_public,
		refundDays: refund_days,
		createdBy: created_by,
		status,
	});

	return {
		...workshop,
		async cleanUp() {
			await deleteE2EFixture("workshop", workshop.id);
		},
	};
}

export async function createStripeCustomerWithSubscription(email: string) {
	const customer = await stripeClient.customers.create({
		email,
		metadata: { source: "test" },
	});
	const paymentMethod = await stripeClient.paymentMethods.create({
		type: "sepa_debit",
		sepa_debit: { iban: "IE29AIBK93115212345678" },
		billing_details: { email, name: "Test User" },
	});
	await stripeClient.paymentMethods.attach(paymentMethod.id, {
		customer: customer.id,
	});
	await stripeClient.customers.update(customer.id, {
		invoice_settings: { default_payment_method: paymentMethod.id },
	});

	const monthlyPrices = await stripeClient.prices.search({
		query: `lookup_key:'${MEMBERSHIP_FEE_LOOKUP_NAME}'`,
	});
	const annualPrices = await stripeClient.prices.search({
		query: `lookup_key:'${ANNUAL_FEE_LOOKUP}'`,
	});
	if (!monthlyPrices.data[0] || !annualPrices.data[0]) {
		throw new Error("Missing Stripe membership prices for E2E setup");
	}

	await stripeClient.subscriptions.create({
		customer: customer.id,
		items: [{ price: monthlyPrices.data[0].id }],
		default_payment_method: paymentMethod.id,
	});
	const subscription = await stripeClient.subscriptions.create({
		customer: customer.id,
		items: [{ price: annualPrices.data[0].id }],
		default_payment_method: paymentMethod.id,
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

export function createUniqueEmail(
	prefix: string,
	index?: number,
	retry?: number,
) {
	const indexPart = index === undefined ? "" : `-${index}`;
	const retryPart = retry === undefined ? "" : `-r${retry}`;
	return `${prefix}-${Date.now()}${indexPart}-${Math.random().toString(36).slice(2, 7)}${retryPart}@test.com`;
}
