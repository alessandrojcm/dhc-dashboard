import { expect, test } from "@playwright/test";
import dayjs from "dayjs";
import type { AttendanceUpdate } from "../src/lib/server/services/workshops/types";
import {
	getWorkshopAttendanceForTest,
	updateWorkshopAttendanceForTest,
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
		const workshopStartDate = dayjs();
		const workshopEndDate = workshopStartDate.add(7, "day");

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

		const attendanceData = await getWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
		);

		expect(attendanceData.success).toBe(true);
		if (!attendanceData.success) {
			throw new Error(attendanceData.error || "Failed to fetch attendance");
		}
		expect(attendanceData.attendance).toBeDefined();
		expect(attendanceData.attendance.length).toBe(3);

		// Check default attendance status
		attendanceData.attendance.forEach((attendee) => {
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
		] satisfies AttendanceUpdate[];

		const updateData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			attendanceUpdates,
		);

		expect(updateData.success).toBe(true);
		if (!updateData.success) {
			throw new Error(updateData.error || "Failed to update attendance");
		}
		expect(updateData.registrations).toBeDefined();
		expect(updateData.registrations.length).toBe(3);

		// Verify updates
		const updatedRegistrations = updateData.registrations;
		expect(
			updatedRegistrations.find(
				(registration) => registration.id === registrationIds[0],
			)?.attendance_status,
		).toBe("attended");
		expect(
			updatedRegistrations.find(
				(registration) => registration.id === registrationIds[1],
			)?.attendance_status,
		).toBe("no_show");
		expect(
			updatedRegistrations.find(
				(registration) => registration.id === registrationIds[2],
			)?.attendance_status,
		).toBe("excused");

		// Verify notes
		expect(
			updatedRegistrations.find(
				(registration) => registration.id === registrationIds[0],
			)?.attendance_notes,
		).toBe("Present and participated");
		expect(
			updatedRegistrations.find(
				(registration) => registration.id === registrationIds[2],
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

		const errorData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			invalidUpdates as unknown as AttendanceUpdate[],
		);
		expect(errorData.success).toBe(false);
		if (errorData.success) {
			throw new Error("Expected invalid attendance payload to fail");
		}
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

		const errorData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			invalidStatusUpdates as unknown as AttendanceUpdate[],
		);
		expect(errorData.success).toBe(false);
		if (errorData.success) {
			throw new Error("Expected invalid attendance status validation to fail");
		}
		expect(errorData.issues).toBeDefined();
	});

	test("should handle empty attendance updates", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const errorData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			[],
		);
		expect(errorData.success).toBe(false);
		if (errorData.success) {
			throw new Error("Expected empty attendance update validation to fail");
		}
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
		] satisfies AttendanceUpdate[];

		const updateData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			attendanceUpdates,
		);

		expect(updateData.success).toBe(true);
		if (!updateData.success) {
			throw new Error(updateData.error || "Failed to update attendance");
		}
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
		] satisfies AttendanceUpdate[];

		const updateData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			attendanceUpdates,
		);

		expect(updateData.success).toBe(true);
		if (!updateData.success) {
			throw new Error(updateData.error || "Failed to update attendance");
		}
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
		] satisfies AttendanceUpdate[];

		const errorData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			attendanceUpdates,
		);
		expect(errorData.success).toBe(false);
		if (errorData.success) {
			throw new Error("Expected long notes validation to fail");
		}
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
		] satisfies AttendanceUpdate[];

		const updateData = await updateWorkshopAttendanceForTest(
			adminData.session,
			workshopId,
			attendanceUpdates,
		);

		expect(updateData.success).toBe(true);
		if (!updateData.success) {
			throw new Error(updateData.error || "Failed to update attendance");
		}
		expect(updateData.registrations.length).toBe(3);

		// Verify all updates were applied
		const registrations = updateData.registrations;
		expect(
			registrations.find(
				(registration) => registration.id === registrationIds[0],
			)?.attendance_status,
		).toBe("attended");
		expect(
			registrations.find(
				(registration) => registration.id === registrationIds[1],
			)?.attendance_status,
		).toBe("no_show");
		expect(
			registrations.find(
				(registration) => registration.id === registrationIds[2],
			)?.attendance_status,
		).toBe("excused");

		// Verify all have marked timestamps and user
		registrations.forEach((registration) => {
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
