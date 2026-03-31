import { expect, test } from "@playwright/test";
import {
	getWorkshopRefundsForTest,
	processWorkshopRefundForTest,
} from "./attendee-test-helpers";
import { createMember, getSupabaseServiceClient } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Refund Management", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let workshopId: string;
	let registrationId: string;

	test.beforeAll(async () => {
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create admin user
		adminData = await createMember({
			email: `admin-refund-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});
	});

	test.beforeEach(async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const supabase = getSupabaseServiceClient();
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create a test workshop directly in database
		const workshopStartDate = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days from now
		const workshopEndDate = new Date(
			workshopStartDate.getTime() + 2 * 60 * 60 * 1000,
		); // 2 hours later

		const { data: workshop, error: workshopError } = await supabase
			.from("club_activities")
			.insert({
				title: `Test Workshop ${timestamp}-${randomSuffix}`,
				description: "Test workshop for refund testing",
				location: "Test Location",
				start_date: workshopStartDate.toISOString(),
				end_date: workshopEndDate.toISOString(),
				max_capacity: 10,
				price_member: 2500, // 25.00 in cents
				price_non_member: 3500, // 35.00 in cents
				is_public: true,
				refund_days: 3,
				status: "published",
			})
			.select()
			.single();

		if (workshopError) {
			throw new Error(`Failed to create workshop: ${workshopError.message}`);
		}
		workshopId = workshop.id;

		// Create a test registration directly in database
		const { data: registration, error: registrationError } = await supabase
			.from("club_activity_registrations")
			.insert({
				club_activity_id: workshopId,
				member_user_id: adminData.userId,
				amount_paid: 2500, // 25.00 in cents
				status: "confirmed",
			})
			.select()
			.single();

		if (registrationError) {
			throw new Error(
				`Failed to create registration: ${registrationError.message}`,
			);
		}
		registrationId = registration.id;
	});

	test("should process refund successfully", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const refundData = await processWorkshopRefundForTest(adminData.session, {
			registration_id: registrationId,
			reason: "Test refund reason",
		});

		expect(refundData.success).toBe(true);
		if (!refundData.success) {
			throw new Error(refundData.error || "Refund request failed");
		}
		expect(refundData.refund).toBeDefined();
		expect(refundData.refund.registration_id).toBe(registrationId);
		expect(refundData.refund.refund_reason).toBe("Test refund reason");
		expect(refundData.refund.status).toBe("pending");
		expect(refundData.refund.refund_amount).toBe(2500);
	});

	test("should not allow duplicate refunds", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		// Process first refund
		const firstRefundResponse = await processWorkshopRefundForTest(
			adminData.session,
			{
				registration_id: registrationId,
				reason: "First refund",
			},
		);

		expect(firstRefundResponse.success).toBe(true);

		// Attempt second refund
		const errorData = await processWorkshopRefundForTest(adminData.session, {
			registration_id: registrationId,
			reason: "Second refund attempt",
		});

		expect(errorData.success).toBe(false);
		if (errorData.success) {
			throw new Error("Expected duplicate refund request to fail");
		}
		expect(errorData.error).toContain("already requested");
	});

	test("should respect refund deadline", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const supabase = getSupabaseServiceClient();
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create workshop with past refund deadline
		const pastWorkshopStartDate = new Date(Date.now() + 24 * 60 * 60 * 1000); // Tomorrow
		const pastWorkshopEndDate = new Date(
			pastWorkshopStartDate.getTime() + 2 * 60 * 60 * 1000,
		);

		const { data: pastWorkshop, error: pastWorkshopError } = await supabase
			.from("club_activities")
			.insert({
				title: `Past Deadline Workshop ${timestamp}-${randomSuffix}`,
				description: "Workshop with past refund deadline",
				location: "Test Location",
				start_date: pastWorkshopStartDate.toISOString(),
				end_date: pastWorkshopEndDate.toISOString(),
				max_capacity: 10,
				price_member: 2500,
				price_non_member: 3500,
				is_public: true,
				refund_days: 7, // 7 days before (already passed)
				status: "published",
			})
			.select()
			.single();

		if (pastWorkshopError) {
			throw new Error(
				`Failed to create past deadline workshop: ${pastWorkshopError.message}`,
			);
		}

		// Create registration for past deadline workshop
		const { data: pastRegistration, error: pastRegistrationError } =
			await supabase
				.from("club_activity_registrations")
				.insert({
					club_activity_id: pastWorkshop.id,
					member_user_id: adminData.userId,
					amount_paid: 2500,
					status: "confirmed",
				})
				.select()
				.single();

		if (pastRegistrationError) {
			throw new Error(
				`Failed to create past registration: ${pastRegistrationError.message}`,
			);
		}

		// Attempt refund
		const errorData = await processWorkshopRefundForTest(adminData.session, {
			registration_id: pastRegistration.id,
			reason: "Late refund attempt",
		});

		expect(errorData.success).toBe(false);
		if (errorData.success) {
			throw new Error("Expected deadline validation to fail");
		}
		expect(errorData.error).toContain("deadline");

		// Cleanup
		await supabase
			.from("club_activity_registrations")
			.delete()
			.eq("id", pastRegistration.id);
		await supabase.from("club_activities").delete().eq("id", pastWorkshop.id);
	});

	test("should fetch workshop refunds", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		// First create a refund
		await processWorkshopRefundForTest(adminData.session, {
			registration_id: registrationId,
			reason: "Test refund for fetching",
		});

		// Fetch refunds
		const refundsData = await getWorkshopRefundsForTest(
			adminData.session,
			workshopId,
		);

		expect(refundsData.success).toBe(true);
		if (!refundsData.success) {
			throw new Error(refundsData.error || "Expected refunds fetch to succeed");
		}
		expect(refundsData.refunds).toBeDefined();
		expect(refundsData.refunds.length).toBe(1);

		const { data: persistedRefunds, error: persistedRefundsError } =
			await getSupabaseServiceClient()
				.from("club_activity_refunds")
				.select("registration_id, refund_reason")
				.eq("registration_id", registrationId);

		if (persistedRefundsError) {
			throw new Error(
				`Failed to verify refund fetch results: ${persistedRefundsError.message}`,
			);
		}

		expect(persistedRefunds).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					registration_id: registrationId,
					refund_reason: "Test refund for fetching",
				}),
			]),
		);
	});

	test("should validate refund request data", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		// Test invalid registration ID
		const invalidIdData = await processWorkshopRefundForTest(
			adminData.session,
			{
				registration_id: "invalid-uuid",
				reason: "Test reason",
			},
		);
		expect(invalidIdData.success).toBe(false);
		if (invalidIdData.success) {
			throw new Error("Expected invalid registration ID validation to fail");
		}
		expect(invalidIdData.issues).toBeDefined();

		// Test missing reason
		const missingReasonData = await processWorkshopRefundForTest(
			adminData.session,
			{
				registration_id: registrationId,
				reason: "",
			},
		);
		expect(missingReasonData.success).toBe(false);
		if (missingReasonData.success) {
			throw new Error("Expected missing reason validation to fail");
		}
		expect(missingReasonData.issues).toBeDefined();
	});

	test("should not allow refund for non-existent registration", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const fakeRegistrationId = "00000000-0000-0000-0000-000000000000";

		const errorData = await processWorkshopRefundForTest(adminData.session, {
			registration_id: fakeRegistrationId,
			reason: "Test refund for non-existent registration",
		});
		expect(errorData.success).toBe(false);
		if (errorData.success) {
			throw new Error("Expected missing registration refund to fail");
		}
		expect(errorData.error).toContain("not found");
	});

	test.afterEach(async () => {
		// Clean up test data
		const supabase = getSupabaseServiceClient();

		if (registrationId) {
			await supabase
				.from("club_activity_registrations")
				.delete()
				.eq("id", registrationId);
		}

		if (workshopId) {
			await supabase.from("club_activities").delete().eq("id", workshopId);
		}
	});

	test.afterAll(async () => {
		if (adminData?.cleanUp) {
			await adminData.cleanUp();
		}
	});
});
