import type { Page } from '@playwright/test';
import type { Database } from '../database.types.js';
import { createMember, getSupabaseServiceClient } from './setupFunctions';

/**
 * Helper functions for attendee management and refund E2E tests
 */

export interface TestWorkshop {
	id: string;
	title: string;
	description: string;
	location: string;
	workshop_date: string;
	workshop_time: string;
	max_capacity: number;
	price_member: number;
	price_non_member: number;
	is_public: boolean;
	refund_deadline_days: number;
}

export interface TestRegistration {
	id: string;
	workshop_id: string;
	member_user_id: string;
	amount_paid: number;
	status: string;
	attendance_status?: string;
	attendance_notes?: string;
	attendance_marked_at?: string;
	attendance_marked_by?: string;
}

export interface TestRefund {
	id: string;
	registration_id: string;
	refund_amount: number;
	refund_reason: string;
	status: string;
	requested_at: string;
}

/**
 * Makes an authenticated API request using Playwright's request context
 */
export async function makeAuthenticatedRequest(
	page: Page,
	url: string,
	options: {
		method?: string;
		data?: unknown;
		headers?: Record<string, string>;
		body?: string;
	} = {}
) {
	const response = await page.request.fetch(url, {
		...options,
		headers: {
			'Content-Type': 'application/json',
			...options.headers
		}
	});
	return response;
}

/**
 * Creates a test workshop with default values using direct database access
 */
export async function createTestWorkshop(
	_page: Page,
	overrides: Partial<Omit<TestWorkshop, 'id'>> = {}
): Promise<TestWorkshop> {
	const timestamp = Date.now();
	const randomSuffix = Math.random().toString(36).substring(2, 15);
	const supabase = getSupabaseServiceClient();

	const workshopStartDate = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days from now
	const workshopEndDate = new Date(workshopStartDate.getTime() + 2 * 60 * 60 * 1000); // 2 hours later

	const defaultWorkshop = {
		title: `Test Workshop ${timestamp}-${randomSuffix}`,
		description: 'Test workshop for E2E testing',
		location: 'Test Location',
		start_date: workshopStartDate.toISOString(),
		end_date: workshopEndDate.toISOString(),
		max_capacity: 10,
		price_member: 2500, // 25.00 in cents
		price_non_member: 3500, // 35.00 in cents
		is_public: true,
		refund_days: 3,
		status: 'published' as const,
		...overrides
	};

	const { data: workshop, error } = await supabase
		.from('club_activities')
		.insert(defaultWorkshop)
		.select()
		.single();

	if (error) {
		throw new Error(`Failed to create workshop: ${error.message}`);
	}

	return {
		id: workshop.id,
		title: workshop.title || '',
		description: workshop.description || '',
		location: workshop.location || '',
		workshop_date: workshop.start_date,
		workshop_time: '14:00', // Default time
		max_capacity: workshop.max_capacity || 0,
		price_member: (workshop.price_member || 0) / 100, // Convert back to dollars
		price_non_member: (workshop.price_non_member || 0) / 100,
		is_public: workshop.is_public || false,
		refund_deadline_days: workshop.refund_days || 0
	};
}

/**
 * Creates a test registration for a workshop using direct database access
 */
export async function createTestRegistration(
	_page: Page,
	workshopId: string,
	userId: string,
	overrides: Partial<Omit<TestRegistration, 'id' | 'workshop_id'>> = {}
): Promise<TestRegistration> {
	const supabase = getSupabaseServiceClient();

	const defaultRegistration = {
		club_activity_id: workshopId,
		member_user_id: userId,
		amount_paid: 2500, // 25.00 in cents
		status: 'confirmed' as const,
		currency: 'EUR',
		...overrides
	};

	const { data: registration, error } = await supabase
		.from('club_activity_registrations')
		.insert(
			defaultRegistration as Database['public']['Tables']['club_activity_registrations']['Insert']
		)
		.select()
		.single();

	if (error) {
		throw new Error(`Failed to create registration: ${error.message}`);
	}

	return {
		id: registration.id,
		workshop_id: workshopId,
		member_user_id: registration.member_user_id || '',
		amount_paid: registration.amount_paid,
		status: registration.status,
		attendance_status: registration.attendance_status || undefined,
		attendance_notes: registration.attendance_notes || undefined
	};
}

/**
 * Creates multiple test registrations for a workshop
 */
export async function createMultipleTestRegistrations(
	page: Page,
	workshopId: string,
	userIds: string[],
	overrides: Partial<Omit<TestRegistration, 'id' | 'workshop_id'>> = {}
): Promise<TestRegistration[]> {
	const registrations: TestRegistration[] = [];

	for (const userId of userIds) {
		const registration = await createTestRegistration(page, workshopId, userId, overrides);
		registrations.push(registration);
	}

	return registrations;
}

/**
 * Creates a test refund for a registration
 */
export async function createTestRefund(
	page: Page,
	workshopId: string,
	registrationId: string,
	reason: string = 'Test refund reason'
): Promise<TestRefund> {
	const response = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/refunds`, {
		method: 'POST',
		data: {
			registration_id: registrationId,
			reason
		}
	});

	if (!response.ok) {
		throw new Error(`Failed to create refund: ${response.status}`);
	}

	const data = await response.json();
	return data.refund;
}

/**
 * Updates attendance for multiple registrations
 */
export async function updateTestAttendance(
	page: Page,
	workshopId: string,
	attendanceUpdates: Array<{
		registration_id: string;
		attendance_status: 'attended' | 'no_show' | 'excused';
		notes?: string;
	}>
): Promise<TestRegistration[]> {
	const response = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/attendance`, {
		method: 'PUT',
		data: { attendance_updates: attendanceUpdates }
	});

	if (!response.ok) {
		throw new Error(`Failed to update attendance: ${response.status}`);
	}

	const data = await response.json();
	return data.registrations;
}

/**
 * Fetches workshop attendance data
 */
export async function getWorkshopAttendance(
	page: Page,
	workshopId: string
): Promise<TestRegistration[]> {
	const response = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/attendance`, {
		method: 'GET'
	});

	if (!response.ok) {
		throw new Error(`Failed to fetch attendance: ${response.status}`);
	}

	const data = await response.json();
	return data.attendance;
}

/**
 * Fetches workshop refunds data
 */
export async function getWorkshopRefunds(page: Page, workshopId: string): Promise<TestRefund[]> {
	const response = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/refunds`, {
		method: 'GET'
	});

	if (!response.ok) {
		throw new Error(`Failed to fetch refunds: ${response.status}`);
	}

	const data = await response.json();
	return data.refunds;
}

/**
 * Creates a workshop with past refund deadline for testing deadline validation
 */
export async function createPastDeadlineWorkshop(page: Page): Promise<TestWorkshop> {
	return createTestWorkshop(page, {
		workshop_date: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(), // Tomorrow
		refund_deadline_days: 7 // 7 days before (already passed)
	});
}

/**
 * Creates a finished workshop for testing refund restrictions
 */
export async function createFinishedWorkshop(page: Page): Promise<TestWorkshop> {
	const workshop = await createTestWorkshop(page, {
		workshop_date: new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString() // Yesterday
	});

	// Mark workshop as finished
	await makeAuthenticatedRequest(page, `/api/workshops/${workshop.id}/finish`, {
		method: 'POST',
		data: {}
	});

	return workshop;
}

/**
 * Creates test users with different roles for testing
 */
export async function createTestUsers() {
	const timestamp = Date.now();
	const randomSuffix = Math.random().toString(36).substring(2, 15);

	const [adminUser, coordinatorUser, memberUser] = await Promise.all([
		createMember({
			email: `admin-test-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['admin'])
		}),
		createMember({
			email: `coordinator-test-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['workshop_coordinator'])
		}),
		createMember({
			email: `member-test-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['member'])
		})
	]);

	return {
		admin: adminUser,
		coordinator: coordinatorUser,
		member: memberUser,
		async cleanUp() {
			await Promise.all([
				adminUser.cleanUp?.(),
				coordinatorUser.cleanUp?.(),
				memberUser.cleanUp?.()
			]);
		}
	};
}

/**
 * Waits for an element to be visible with a custom timeout
 */
export async function waitForElement(page: Page, selector: string, timeout: number = 10000) {
	return page.waitForSelector(selector, { state: 'visible', timeout });
}

/**
 * Waits for loading to complete (no loading spinners visible)
 */
export async function waitForLoadingComplete(page: Page, timeout: number = 15000) {
	await page.waitForSelector('.animate-spin', { state: 'hidden', timeout });
}

/**
 * Fills a form field and waits for it to be updated
 */
export async function fillFormField(page: Page, selector: string, value: string) {
	await page.fill(selector, value);
	await page.waitForFunction(
		({ selector, value }) => {
			const element = document.querySelector(selector) as HTMLInputElement | HTMLTextAreaElement;
			return element && element.value === value;
		},
		{ selector, value }
	);
}

/**
 * Selects an option from a dropdown and waits for it to be selected
 */
export async function selectDropdownOption(page: Page, selector: string, value: string) {
	await page.selectOption(selector, value);
	await page.waitForFunction(
		({ selector, value }) => {
			const element = document.querySelector(selector);
			return element && (element as HTMLSelectElement).value === value;
		},
		{ selector, value }
	);
}

/**
 * Clicks a button and waits for the action to complete
 */
export async function clickAndWait(page: Page, selector: string, waitForSelector?: string) {
	await page.click(selector);
	if (waitForSelector) {
		await page.waitForSelector(waitForSelector, { state: 'visible' });
	}
}

/**
 * Validates that an API response has the expected success format
 */
export function validateApiResponse(data: Record<string, unknown>, expectedResource?: string) {
	if (!data.success) {
		throw new Error(`API request failed: ${data.error || 'Unknown error'}`);
	}

	if (expectedResource && !data[expectedResource]) {
		throw new Error(`Expected resource '${expectedResource}' not found in response`);
	}

	return data;
}

/**
 * Generates unique test data to avoid conflicts
 */
export function generateUniqueTestData(prefix: string = 'test') {
	const timestamp = Date.now();
	const randomSuffix = Math.random().toString(36).substring(2, 15);
	return `${prefix}-${timestamp}-${randomSuffix}`;
}

/**
 * Creates a date in the future for workshop scheduling
 */
export function createFutureDate(daysFromNow: number = 7): string {
	return new Date(Date.now() + daysFromNow * 24 * 60 * 60 * 1000).toISOString();
}

/**
 * Creates a date in the past for testing finished workshops
 */
export function createPastDate(daysAgo: number = 1): string {
	return new Date(Date.now() - daysAgo * 24 * 60 * 60 * 1000).toISOString();
}
