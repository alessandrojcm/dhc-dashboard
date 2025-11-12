import { test, expect } from '@playwright/test';
import { createMember, getSupabaseServiceClient } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
import { makeAuthenticatedRequest, createTestWorkshop } from './attendee-test-helpers';

test.describe('Workshop Full Lifecycle E2E', () => {
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
			roles: new Set(['admin'])
		});

		// Create three member users for different scenarios
		member1Data = await createMember({
			email: `member1-lifecycle-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['member'])
		});

		member2Data = await createMember({
			email: `member2-lifecycle-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['member'])
		});

		member3Data = await createMember({
			email: `member3-lifecycle-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['member'])
		});
	});

	test('complete workshop lifecycle: admin creates workshop, 3 users pay, 1 self-cancels, 1 admin-refunds, 1 marked attended', async ({
		page,
		context
	}) => {
		// Step 1: Admin creates a workshop using test helper (same as attendee-management-ui.spec.ts)
		await loginAsUser(context, adminData.email);
		await page.goto('/dashboard');

		const timestamp = Date.now();
		const workshopTitle = `Full Lifecycle Workshop ${timestamp}`;

		// Create workshop using helper function (creates directly in database)
		const workshop = await createTestWorkshop(page, {
			title: workshopTitle,
			description: 'Complete lifecycle test workshop',
			location: 'Test Location',
			max_capacity: 10,
			price_member: 25,
			price_non_member: 35,
			is_public: true
		});
		workshopId = workshop.id;

		// Workshop is created as 'published' by default in createTestWorkshop

		// Step 2: Three users register and pay for the workshop
		// Create registrations directly in database (simulating successful Stripe payments)
		const supabase = getSupabaseServiceClient();

		const { data: registration1, error: reg1Error } = await supabase
			.from('club_activity_registrations')
			.insert({
				club_activity_id: workshopId,
				member_user_id: member1Data.userId,
				amount_paid: 2500, // 25.00 in cents
				status: 'confirmed',
				currency: 'EUR'
			})
			.select()
			.single();

		if (reg1Error) {
			throw new Error(`Failed to create registration 1: ${reg1Error.message}`);
		}
		registration1Id = registration1.id;

		const { data: registration2, error: reg2Error } = await supabase
			.from('club_activity_registrations')
			.insert({
				club_activity_id: workshopId,
				member_user_id: member2Data.userId,
				amount_paid: 2500, // 25.00 in cents
				status: 'confirmed',
				currency: 'EUR'
			})
			.select()
			.single();

		if (reg2Error) {
			throw new Error(`Failed to create registration 2: ${reg2Error.message}`);
		}
		registration2Id = registration2.id;

		const { data: registration3, error: reg3Error } = await supabase
			.from('club_activity_registrations')
			.insert({
				club_activity_id: workshopId,
				member_user_id: member3Data.userId,
				amount_paid: 2500, // 25.00 in cents
				status: 'confirmed',
				currency: 'EUR'
			})
			.select()
			.single();

		if (reg3Error) {
			throw new Error(`Failed to create registration 3: ${reg3Error.message}`);
		}
		registration3Id = registration3.id;

		// Verify registrations were created
		const { data: registrations, error: regError } = await supabase
			.from('club_activity_registrations')
			.select('*')
			.eq('club_activity_id', workshopId);

		if (regError) {
			throw new Error(`Failed to fetch registrations: ${regError.message}`);
		}

		expect(registrations).toHaveLength(3);
		expect(registrations.every((reg: any) => reg.status === 'confirmed')).toBe(true);

		// Step 3: Member 1 cancels and gets a refund (self-service)
		// Login as member 1 and request refund
		await loginAsUser(context, member1Data.email);
		await page.goto('/dashboard');

		// Request refund via API (simulating user-initiated refund)
		const refund1Response = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/refunds`,
			{
				method: 'POST',
				data: {
					registration_id: registration1Id,
					reason: 'Personal scheduling conflict'
				}
			}
		);

		if (!refund1Response.ok()) {
			const errorText = await refund1Response.text();
			console.error('Refund 1 failed:', refund1Response.status(), errorText);
			throw new Error(`Refund 1 failed: ${refund1Response.status()} - ${errorText}`);
		}
		const refund1Data = await refund1Response.json();
		expect(refund1Data.success).toBe(true);
		expect(refund1Data.refund.registration_id).toBe(registration1Id);
		expect(refund1Data.refund.refund_reason).toBe('Personal scheduling conflict');
		expect(refund1Data.refund.status).toBe('pending');

		// Step 4: Admin manually refunds member 2
		await loginAsUser(context, adminData.email);
		await page.goto('/dashboard');

		const refund2Response = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/refunds`,
			{
				method: 'POST',
				data: {
					registration_id: registration2Id,
					reason: 'Admin-initiated refund due to injury'
				}
			}
		);

		expect(refund2Response.ok()).toBeTruthy();
		const refund2Data = await refund2Response.json();
		expect(refund2Data.success).toBe(true);
		expect(refund2Data.refund.registration_id).toBe(registration2Id);
		expect(refund2Data.refund.refund_reason).toBe('Admin-initiated refund due to injury');
		expect(refund2Data.refund.status).toBe('pending');

		// Step 5: Admin marks member 3 as attended
		const attendanceResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: 'PUT',
				data: {
					attendance_updates: [
						{
							registration_id: registration3Id,
							attendance_status: 'attended',
							notes: 'Excellent participation and technique improvement'
						}
					]
				}
			}
		);

		expect(attendanceResponse.ok()).toBeTruthy();
		const attendanceData = await attendanceResponse.json();
		expect(attendanceData.success).toBe(true);
		expect(attendanceData.registrations).toHaveLength(1);
		expect(attendanceData.registrations[0].attendance_status).toBe('attended');
		expect(attendanceData.registrations[0].attendance_notes).toBe(
			'Excellent participation and technique improvement'
		);
		expect(attendanceData.registrations[0].attendance_marked_by).toBe(adminData.userId);

		// Step 6: Verify final state
		// Check refunds were created
		const refundsResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/refunds`,
			{
				method: 'GET'
			}
		);

		expect(refundsResponse.ok()).toBeTruthy();
		const refundsData = await refundsResponse.json();
		expect(refundsData.success).toBe(true);
		expect(refundsData.refunds).toHaveLength(2);

		// Verify refund details
		const member1Refund = refundsData.refunds.find(
			(r: any) => r.registration_id === registration1Id
		);
		const member2Refund = refundsData.refunds.find(
			(r: any) => r.registration_id === registration2Id
		);

		expect(member1Refund).toBeDefined();
		expect(member1Refund.refund_reason).toBe('Personal scheduling conflict');
		expect(member1Refund.refund_amount).toBe(2500);

		expect(member2Refund).toBeDefined();
		expect(member2Refund.refund_reason).toBe('Admin-initiated refund due to injury');
		expect(member2Refund.refund_amount).toBe(2500);

		// Check attendance was recorded
		const finalAttendanceResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/attendance`,
			{
				method: 'GET'
			}
		);

		expect(finalAttendanceResponse.ok()).toBeTruthy();
		const finalAttendanceData = await finalAttendanceResponse.json();
		expect(finalAttendanceData.success).toBe(true);
		expect(finalAttendanceData.attendance).toHaveLength(3);

		// Find member 3's attendance record
		const member3Attendance = finalAttendanceData.attendance.find(
			(a: any) => a.registration_id === registration3Id
		);
		expect(member3Attendance).toBeDefined();
		expect(member3Attendance.attendance_status).toBe('attended');
		expect(member3Attendance.attendance_notes).toBe(
			'Excellent participation and technique improvement'
		);

		// Verify refunded members have different statuses
		const member1Attendance = finalAttendanceData.attendance.find(
			(a: any) => a.registration_id === registration1Id
		);
		const member2Attendance = finalAttendanceData.attendance.find(
			(a: any) => a.registration_id === registration2Id
		);

		// These should still exist but with pending attendance status since they were refunded
		expect(member1Attendance).toBeDefined();
		expect(member2Attendance).toBeDefined();
		expect(member1Attendance.attendance_status).toBe('pending');
		expect(member2Attendance.attendance_status).toBe('pending');

		// Step 7: Verify workshop statistics
		// The workshop should show:
		// - 3 total registrations
		// - 2 refunds processed
		// - 1 attendee marked as attended
		// - 2 registrations with refunds (but still in system for record keeping)

		await page.goto('/dashboard/workshops');
		const finalWorkshopCard = page.locator('article').filter({ hasText: workshopTitle });
		await expect(finalWorkshopCard).toBeVisible();
		await expect(finalWorkshopCard.getByText('published')).toBeVisible();

		console.log('✅ Full workshop lifecycle test completed successfully:');
		console.log('   - Admin created and published workshop');
		console.log('   - 3 members registered and paid');
		console.log('   - Member 1 self-cancelled with refund');
		console.log('   - Admin manually refunded Member 2');
		console.log('   - Member 3 marked as attended');
		console.log('   - All data verified in final state');
	});

	test.afterEach(async () => {
		// Clean up test data
		const supabase = getSupabaseServiceClient();

		// Clean up registrations (this will cascade to refunds)
		if (registration1Id || registration2Id || registration3Id) {
			const registrationIds = [registration1Id, registration2Id, registration3Id].filter(Boolean);
			if (registrationIds.length > 0) {
				await supabase.from('club_activity_registrations').delete().in('id', registrationIds);
			}
		}

		// Clean up workshop
		if (workshopId) {
			await supabase.from('club_activities').delete().eq('id', workshopId);
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
