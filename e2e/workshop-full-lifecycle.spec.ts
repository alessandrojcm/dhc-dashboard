import { expect, test } from "@playwright/test";
import {
	createTestWorkshop,
	getWorkshopAttendanceForTest,
	getWorkshopRefundsForTest,
	processWorkshopRefundForTest,
	updateWorkshopAttendanceForTest,
} from "./attendee-test-helpers";
import { createMember, getSupabaseServiceClient } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Workshop Full Lifecycle E2E", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let member1Data: Awaited<ReturnType<typeof createMember>>;
	let member2Data: Awaited<ReturnType<typeof createMember>>;
	let member3Data: Awaited<ReturnType<typeof createMember>>;
	let workshopId: string;
	let registration1Id: string;
	let registration2Id: string;
	let registration3Id: string;

	test.beforeAll(async () => {
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create admin user
		adminData = await createMember({
			email: `admin-lifecycle-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});

		// Create three member users for different scenarios
		member1Data = await createMember({
			email: `member1-lifecycle-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["member"]),
		});

		member2Data = await createMember({
			email: `member2-lifecycle-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["member"]),
		});

		member3Data = await createMember({
			email: `member3-lifecycle-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["member"]),
		});
	});

	test("complete workshop lifecycle: admin creates workshop, 3 users pay, 1 self-cancels, 1 admin-refunds, 1 marked attended", async ({
		page,
		context,
	}) => {
		// Step 1: Admin creates a workshop using test helper (same as attendee-management-ui.spec.ts)
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const timestamp = Date.now();
		const workshopTitle = `Full Lifecycle Workshop ${timestamp}`;

		// Create workshop using helper function (creates directly in database)
		const workshop = await createTestWorkshop(page, {
			title: workshopTitle,
			description: "Complete lifecycle test workshop",
			location: "Test Location",
			max_capacity: 10,
			price_member: 25,
			price_non_member: 35,
			is_public: true,
		});
		workshopId = workshop.id;

		// Workshop is created as 'published' by default in createTestWorkshop

		// Step 2: Three users register and pay for the workshop
		// Create registrations directly in database (simulating successful Stripe payments)
		const supabase = getSupabaseServiceClient();

		const { data: registration1, error: reg1Error } = await supabase
			.from("club_activity_registrations")
			.insert({
				club_activity_id: workshopId,
				member_user_id: member1Data.userId,
				amount_paid: 2500, // 25.00 in cents
				status: "confirmed",
				currency: "EUR",
			})
			.select()
			.single();

		if (reg1Error) {
			throw new Error(`Failed to create registration 1: ${reg1Error.message}`);
		}
		registration1Id = registration1.id;

		const { data: registration2, error: reg2Error } = await supabase
			.from("club_activity_registrations")
			.insert({
				club_activity_id: workshopId,
				member_user_id: member2Data.userId,
				amount_paid: 2500, // 25.00 in cents
				status: "confirmed",
				currency: "EUR",
			})
			.select()
			.single();

		if (reg2Error) {
			throw new Error(`Failed to create registration 2: ${reg2Error.message}`);
		}
		registration2Id = registration2.id;

		const { data: registration3, error: reg3Error } = await supabase
			.from("club_activity_registrations")
			.insert({
				club_activity_id: workshopId,
				member_user_id: member3Data.userId,
				amount_paid: 2500, // 25.00 in cents
				status: "confirmed",
				currency: "EUR",
			})
			.select()
			.single();

		if (reg3Error) {
			throw new Error(`Failed to create registration 3: ${reg3Error.message}`);
		}
		registration3Id = registration3.id;

		// Verify registrations were created
		const { data: registrations, error: regError } = await supabase
			.from("club_activity_registrations")
			.select("*")
			.eq("club_activity_id", workshopId);

		if (regError) {
			throw new Error(`Failed to fetch registrations: ${regError.message}`);
		}

		expect(registrations).toHaveLength(3);
		expect(
			registrations.every(
				(reg: { status: string }) => reg.status === "confirmed",
			),
		).toBe(true);

		// Step 3: Member 1 cancels and gets a refund (self-service)
		// Login as member 1 and request refund
		await loginAsUser(context, member1Data.email);
		await page.goto("/dashboard");

		// Request refund via API (simulating user-initiated refund)
		const refund1Data = await processWorkshopRefundForTest(
			member1Data.session,
			{
				registration_id: registration1Id,
				reason: "Personal scheduling conflict",
			},
		);
		expect(refund1Data.success).toBe(true);
		if (!refund1Data.success) {
			throw new Error(refund1Data.error || "Refund 1 failed");
		}
		expect(refund1Data.refund.registration_id).toBe(registration1Id);
		expect(refund1Data.refund.refund_reason).toBe(
			"Personal scheduling conflict",
		);
		expect(refund1Data.refund.status).toBe("pending");

		// Step 4: Admin manually refunds member 2
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const refund2Data = await processWorkshopRefundForTest(adminData.session, {
			registration_id: registration2Id,
			reason: "Admin-initiated refund due to injury",
		});
		expect(refund2Data.success).toBe(true);
		if (!refund2Data.success) {
			throw new Error(refund2Data.error || "Refund 2 failed");
		}
		expect(refund2Data.refund.registration_id).toBe(registration2Id);
		expect(refund2Data.refund.refund_reason).toBe(
			"Admin-initiated refund due to injury",
		);
		expect(refund2Data.refund.status).toBe("pending");

		// Step 5: Admin marks member 3 as attended
		const attendanceData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			[
				{
					registration_id: registration3Id,
					attendance_status: "attended",
					notes: "Excellent participation and technique improvement",
				},
			],
		);
		expect(attendanceData.success).toBe(true);
		if (!attendanceData.success) {
			throw new Error(attendanceData.error || "Attendance update failed");
		}
		expect(attendanceData.registrations).toHaveLength(1);
		expect(attendanceData.registrations[0].attendance_status).toBe("attended");
		expect(attendanceData.registrations[0].attendance_notes).toBe(
			"Excellent participation and technique improvement",
		);
		expect(attendanceData.registrations[0].attendance_marked_by).toBe(
			adminData.userId,
		);

		// Step 6: Verify final state
		// Check refunds were created
		const refundsData = await getWorkshopRefundsForTest(
			adminData.session,
			workshopId,
		);
		expect(refundsData.success).toBe(true);
		if (!refundsData.success) {
			throw new Error(refundsData.error || "Failed to fetch refunds");
		}
		expect(refundsData.refunds).toHaveLength(2);

		const { data: persistedRefunds, error: persistedRefundsError } =
			await supabase
				.from("club_activity_refunds")
				.select("registration_id, refund_reason, refund_amount")
				.in("registration_id", [registration1Id, registration2Id]);

		if (persistedRefundsError) {
			throw new Error(
				`Failed to verify persisted refunds: ${persistedRefundsError.message}`,
			);
		}

		expect(persistedRefunds).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					registration_id: registration1Id,
					refund_reason: "Personal scheduling conflict",
					refund_amount: 2500,
				}),
				expect.objectContaining({
					registration_id: registration2Id,
					refund_reason: "Admin-initiated refund due to injury",
					refund_amount: 2500,
				}),
			]),
		);

		// Check attendance was recorded
		const finalAttendanceData = await getWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
		);
		expect(finalAttendanceData.success).toBe(true);
		if (!finalAttendanceData.success) {
			throw new Error(
				finalAttendanceData.error || "Failed to fetch attendance",
			);
		}
		expect(finalAttendanceData.attendance).toHaveLength(1);

		// Find member 3's attendance record
		const member3Attendance = finalAttendanceData.attendance.find(
			(a: { id: string }) => a.id === registration3Id,
		);
		expect(member3Attendance).toBeDefined();
		if (!member3Attendance) {
			throw new Error("Expected member 3 attendance record to exist");
		}
		expect(member3Attendance.attendance_status).toBe("attended");
		expect(member3Attendance.attendance_notes).toBe(
			"Excellent participation and technique improvement",
		);

		const { data: refundedRegistrations, error: refundedRegistrationsError } =
			await supabase
				.from("club_activity_registrations")
				.select("id, status")
				.in("id", [registration1Id, registration2Id]);

		if (refundedRegistrationsError) {
			throw new Error(
				`Failed to verify refunded registrations: ${refundedRegistrationsError.message}`,
			);
		}

		expect(refundedRegistrations).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ id: registration1Id, status: "refunded" }),
				expect.objectContaining({ id: registration2Id, status: "refunded" }),
			]),
		);

		// Step 7: Verify workshop statistics
		// The workshop should show:
		// - 3 total registrations
		// - 2 refunds processed
		// - 1 attendee marked as attended
		// - 2 registrations with refunds (but still in system for record keeping)

		await page.goto("/dashboard/workshops");
		const finalWorkshopCard = page
			.locator("article")
			.filter({ hasText: workshopTitle });
		await expect(finalWorkshopCard).toBeVisible();
		await expect(finalWorkshopCard.getByText("published")).toBeVisible();

		console.log("✅ Full workshop lifecycle test completed successfully:");
		console.log("   - Admin created and published workshop");
		console.log("   - 3 members registered and paid");
		console.log("   - Member 1 self-cancelled with refund");
		console.log("   - Admin manually refunded Member 2");
		console.log("   - Member 3 marked as attended");
		console.log("   - All data verified in final state");
	});

	test.afterEach(async () => {
		// Clean up test data
		const supabase = getSupabaseServiceClient();

		// Clean up registrations (this will cascade to refunds)
		if (registration1Id || registration2Id || registration3Id) {
			const registrationIds = [
				registration1Id,
				registration2Id,
				registration3Id,
			].filter(Boolean);
			if (registrationIds.length > 0) {
				await supabase
					.from("club_activity_registrations")
					.delete()
					.in("id", registrationIds);
			}
		}

		// Clean up workshop
		if (workshopId) {
			await supabase.from("club_activities").delete().eq("id", workshopId);
		}
	});

	test.afterAll(async () => {
		// Clean up test users
		if (adminData?.cleanUp) {
			await adminData.cleanUp();
		}
		if (member1Data?.cleanUp) {
			await member1Data.cleanUp();
		}
		if (member2Data?.cleanUp) {
			await member2Data.cleanUp();
		}
		if (member3Data?.cleanUp) {
			await member3Data.cleanUp();
		}
	});
});
