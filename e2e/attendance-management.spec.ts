import { expect, test } from "@playwright/test";
import {
	makeAuthenticatedRequest,
	type TestRegistration,
} from "./attendee-test-helpers";
import { createMember, getSupabaseServiceClient } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Attendance Management", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let testMembers: Awaited<ReturnType<typeof createMember>>[] = [];
	let workshopId: string;
	let registrationIds: string[] = [];

	test.beforeAll(async () => {
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create admin user
		adminData = await createMember({
			email: `admin-attendance-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});
	});

	test.beforeEach(async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const supabase = getSupabaseServiceClient();
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create test workshop directly in database
		const workshopStartDate = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
		const workshopEndDate = new Date(
			workshopStartDate.getTime() + 2 * 60 * 60 * 1000,
		);

		const { data: workshop, error: workshopError } = await supabase
			.from("club_activities")
			.insert({
				title: `Attendance Test Workshop ${timestamp}-${randomSuffix}`,
				description: "Test workshop for attendance tracking",
				location: "Test Location",
				start_date: workshopStartDate.toISOString(),
				end_date: workshopEndDate.toISOString(),
				max_capacity: 10,
				price_member: 2500,
				price_non_member: 3500,
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

		// Create multiple test members and registrations
		registrationIds = [];
		testMembers = [];
		for (let i = 0; i < 3; i++) {
			// Create unique test member for each registration
			const memberData = await createMember({
				email: `member-${i}-${timestamp}-${randomSuffix}@test.com`,
				roles: new Set(["member"]),
			});
			testMembers.push(memberData);

			const { data: registration, error: registrationError } = await supabase
				.from("club_activity_registrations")
				.insert({
					club_activity_id: workshopId,
					member_user_id: memberData.userId,
					amount_paid: 2500,
					status: "confirmed",
				})
				.select()
				.single();

			if (registrationError) {
				throw new Error(
					`Failed to create registration ${i}: ${registrationError.message}`,
				);
			}
			registrationIds.push(registration.id);
		}
	});

	test("should fetch workshop attendance", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const attendanceResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "GET",
			},
		);

		expect(attendanceResponse.ok()).toBeTruthy();
		const attendanceData = await attendanceResponse.json();

		expect(attendanceData.success).toBe(true);
		expect(attendanceData.attendance).toBeDefined();
		expect(attendanceData.attendance.length).toBe(3);

		// Check default attendance status
		attendanceData.attendance.forEach((attendee: TestRegistration) => {
			expect(attendee.attendance_status).toBe("pending");
		});
	});

	test("should update attendance status", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const attendanceUpdates = [
			{
				registration_id: registrationIds[0],
				attendance_status: "attended",
				notes: "Present and participated",
			},
			{
				registration_id: registrationIds[1],
				attendance_status: "no_show",
			},
			{
				registration_id: registrationIds[2],
				attendance_status: "excused",
				notes: "Family emergency",
			},
		];

		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "PUT",
				data: { attendance_updates: attendanceUpdates },
			},
		);

		expect(updateResponse.ok()).toBeTruthy();
		const updateData = await updateResponse.json();

		expect(updateData.success).toBe(true);
		expect(updateData.registrations).toBeDefined();
		expect(updateData.registrations.length).toBe(3);

		// Verify updates
		const updatedRegistrations = updateData.registrations;
		expect(
			updatedRegistrations.find(
				(r: TestRegistration) => r.id === registrationIds[0],
			)?.attendance_status,
		).toBe("attended");
		expect(
			updatedRegistrations.find(
				(r: TestRegistration) => r.id === registrationIds[1],
			)?.attendance_status,
		).toBe("no_show");
		expect(
			updatedRegistrations.find(
				(r: TestRegistration) => r.id === registrationIds[2],
			)?.attendance_status,
		).toBe("excused");

		// Verify notes
		expect(
			updatedRegistrations.find(
				(r: TestRegistration) => r.id === registrationIds[0],
			)?.attendance_notes,
		).toBe("Present and participated");
		expect(
			updatedRegistrations.find(
				(r: TestRegistration) => r.id === registrationIds[2],
			)?.attendance_notes,
		).toBe("Family emergency");
	});

	test("should validate attendance update data", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const invalidUpdates = [
			{
				registration_id: "invalid-uuid",
				attendance_status: "attended",
			},
		];

		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "PUT",
				data: { attendance_updates: invalidUpdates },
			},
		);

		expect(updateResponse.ok()).toBeFalsy();
		const errorData = await updateResponse.json();
		expect(errorData.success).toBe(false);
		expect(errorData.issues).toBeDefined();
	});

	test("should validate attendance status values", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const invalidStatusUpdates = [
			{
				registration_id: registrationIds[0],
				attendance_status: "invalid_status",
			},
		];

		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "PUT",
				data: { attendance_updates: invalidStatusUpdates },
			},
		);

		expect(updateResponse.ok()).toBeFalsy();
		const errorData = await updateResponse.json();
		expect(errorData.success).toBe(false);
		expect(errorData.issues).toBeDefined();
	});

	test("should handle empty attendance updates", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "PUT",
				data: { attendance_updates: [] },
			},
		);

		expect(updateResponse.ok()).toBeFalsy();
		const errorData = await updateResponse.json();
		expect(errorData.success).toBe(false);
		expect(errorData.issues).toBeDefined();
	});

	test("should update attendance with notes only", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const attendanceUpdates = [
			{
				registration_id: registrationIds[0],
				attendance_status: "attended",
				notes: "Excellent participation and technique",
			},
		];

		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "PUT",
				data: { attendance_updates: attendanceUpdates },
			},
		);

		expect(updateResponse.ok()).toBeTruthy();
		const updateData = await updateResponse.json();

		expect(updateData.success).toBe(true);
		expect(updateData.registrations).toBeDefined();
		expect(updateData.registrations.length).toBe(1);
		expect(updateData.registrations[0].attendance_notes).toBe(
			"Excellent participation and technique",
		);
		expect(updateData.registrations[0].attendance_marked_at).toBeDefined();
		expect(updateData.registrations[0].attendance_marked_by).toBe(
			adminData.userId,
		);
	});

	test("should handle long notes within character limit", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const longNotes = "A".repeat(500); // Exactly at the limit
		const attendanceUpdates = [
			{
				registration_id: registrationIds[0],
				attendance_status: "attended",
				notes: longNotes,
			},
		];

		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "PUT",
				data: { attendance_updates: attendanceUpdates },
			},
		);

		expect(updateResponse.ok()).toBeTruthy();
		const updateData = await updateResponse.json();

		expect(updateData.success).toBe(true);
		expect(updateData.registrations[0].attendance_notes).toBe(longNotes);
	});

	test("should reject notes exceeding character limit", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const tooLongNotes = "A".repeat(501); // Over the limit
		const attendanceUpdates = [
			{
				registration_id: registrationIds[0],
				attendance_status: "attended",
				notes: tooLongNotes,
			},
		];

		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "PUT",
				data: { attendance_updates: attendanceUpdates },
			},
		);

		expect(updateResponse.ok()).toBeFalsy();
		const errorData = await updateResponse.json();
		expect(errorData.success).toBe(false);
		expect(errorData.issues).toBeDefined();
	});

	test("should update multiple attendees with different statuses", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const attendanceUpdates = [
			{
				registration_id: registrationIds[0],
				attendance_status: "attended",
			},
			{
				registration_id: registrationIds[1],
				attendance_status: "no_show",
			},
			{
				registration_id: registrationIds[2],
				attendance_status: "excused",
			},
		];

		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: "PUT",
				data: { attendance_updates: attendanceUpdates },
			},
		);

		expect(updateResponse.ok()).toBeTruthy();
		const updateData = await updateResponse.json();

		expect(updateData.success).toBe(true);
		expect(updateData.registrations.length).toBe(3);

		// Verify all updates were applied
		const registrations = updateData.registrations;
		expect(
			registrations.find((r: TestRegistration) => r.id === registrationIds[0])
				?.attendance_status,
		).toBe("attended");
		expect(
			registrations.find((r: TestRegistration) => r.id === registrationIds[1])
				?.attendance_status,
		).toBe("no_show");
		expect(
			registrations.find((r: TestRegistration) => r.id === registrationIds[2])
				?.attendance_status,
		).toBe("excused");

		// Verify all have marked timestamps and user
		registrations.forEach((registration: TestRegistration) => {
			expect(registration.attendance_marked_at).toBeDefined();
			expect(registration.attendance_marked_by).toBe(adminData.userId);
		});
	});

	test.afterEach(async () => {
		// Clean up test data
		const supabase = getSupabaseServiceClient();

		if (registrationIds.length > 0) {
			await supabase
				.from("club_activity_registrations")
				.delete()
				.in("id", registrationIds);
		}

		if (workshopId) {
			await supabase.from("club_activities").delete().eq("id", workshopId);
		}

		// Clean up test members
		for (const member of testMembers) {
			if (member?.cleanUp) {
				await member.cleanUp();
			}
		}
		testMembers = [];
	});

	test.afterAll(async () => {
		if (adminData?.cleanUp) {
			await adminData.cleanUp();
		}
	});
});
