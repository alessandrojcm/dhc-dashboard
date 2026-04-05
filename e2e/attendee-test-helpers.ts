import type { Page } from "@playwright/test";
import type { Session } from "@supabase/supabase-js";
import * as v from "valibot";
import type { Database } from "../src/database.types";
import { getKyselyClient } from "../src/lib/server/kysely";
import { AttendanceService } from "../src/lib/server/services/workshops/attendance.service";
import { RefundService } from "../src/lib/server/services/workshops/refund.service";
import { RegistrationService } from "../src/lib/server/services/workshops/registration.service";
import type {
	AttendanceResult,
	AttendanceUpdate,
	RefundWithUser,
	ToggleInterestResult,
	Workshop,
} from "../src/lib/server/services/workshops/types";
import { WorkshopService } from "../src/lib/server/services/workshops/workshop.service";
import {
	createMember,
	getSupabaseServiceClient,
	stripeClient,
} from "./setupFunctions";

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

type ServiceResult<T> =
	| ({ success: true } & T)
	| {
			success: false;
			error?: string;
			issues?: unknown;
	  };

type CreateTestWorkshopOverrides = Partial<
	Database["public"]["Tables"]["club_activities"]["Insert"]
>;

type CreateTestRegistrationOverrides = Partial<
	Omit<
		Database["public"]["Tables"]["club_activity_registrations"]["Insert"],
		"club_activity_id" | "member_user_id"
	>
>;

type RoleType = Database["public"]["Enums"]["role_type"];

const testLogger = {
	info(message: string, context?: Record<string, unknown>) {
		console.info(message, context);
	},
	error(message: string, context?: Record<string, unknown>) {
		console.error(message, context);
	},
	warn(message: string, context?: Record<string, unknown>) {
		console.warn(message, context);
	},
	debug(message: string, context?: Record<string, unknown>) {
		console.debug(message, context);
	},
};

const RefundRequestSchema = v.object({
	registration_id: v.pipe(v.string(), v.uuid()),
	reason: v.pipe(
		v.string(),
		v.minLength(1, "Reason is required"),
		v.maxLength(500, "Reason must be less than 500 characters"),
	),
});

const AttendanceUpdatesSchema = v.object({
	attendance_updates: v.pipe(
		v.array(
			v.object({
				registration_id: v.pipe(v.string(), v.uuid()),
				attendance_status: v.picklist(["attended", "no_show", "excused"]),
				notes: v.optional(
					v.pipe(
						v.string(),
						v.maxLength(500, "Notes must be less than 500 characters"),
					),
				),
			}),
		),
		v.minLength(1, "At least one attendance update required"),
	),
});

let _kysely: ReturnType<typeof getKyselyClient> | null = null;

function getWorkshopServiceConnectionString() {
	const connectionString =
		process.env.HYPERDRIVE ?? process.env.POSTGRES_CONNECTION_STRING;

	if (!connectionString) {
		throw new Error(
			"Missing HYPERDRIVE or POSTGRES_CONNECTION_STRING for service-backed workshop E2E helpers",
		);
	}

	return connectionString;
}

function getWorkshopServiceKysely() {
	if (_kysely) {
		return _kysely;
	}

	_kysely = getKyselyClient(getWorkshopServiceConnectionString());
	return _kysely;
}

export function createWorkshopTestServices(session: Session) {
	const kysely = getWorkshopServiceKysely();
	// For E2E tests, we use a member actor context derived from the session
	const memberActor = {
		kind: "member" as const,
		memberUserId: session.user.id,
	};

	return {
		workshopService: new WorkshopService(
			kysely,
			session,
			stripeClient,
			testLogger,
		),
		attendanceService: new AttendanceService(kysely, session, testLogger),
		refundService: new RefundService(kysely, session, stripeClient, testLogger),
		registrationService: new RegistrationService(
			kysely,
			session,
			memberActor,
			stripeClient,
			testLogger,
		),
	};
}

export async function publishWorkshopForTest(
	session: Session,
	workshopId: string,
): Promise<ServiceResult<{ workshop: Workshop }>> {
	try {
		const { workshopService } = createWorkshopTestServices(session);
		const workshop = await workshopService.publish(workshopId);
		return { success: true, workshop };
	} catch (error) {
		return {
			success: false,
			error:
				error instanceof Error ? error.message : "Failed to publish workshop",
		};
	}
}

export async function toggleWorkshopInterestForTest(
	session: Session,
	workshopId: string,
): Promise<ServiceResult<ToggleInterestResult>> {
	try {
		const { registrationService } = createWorkshopTestServices(session);
		const result = await registrationService.toggleInterest(workshopId);
		return { success: true, ...result };
	} catch (error) {
		return {
			success: false,
			error:
				error instanceof Error
					? error.message
					: "Failed to toggle workshop interest",
		};
	}
}

export async function processWorkshopRefundForTest(
	session: Session,
	input: { registration_id: string; reason: string },
): Promise<ServiceResult<{ refund: TestRefund }>> {
	const validatedInput = v.safeParse(RefundRequestSchema, input);

	if (!validatedInput.success) {
		return { success: false, issues: validatedInput.issues };
	}

	try {
		const { refundService } = createWorkshopTestServices(session);
		const refund = await refundService.processRefund(
			validatedInput.output.registration_id,
			validatedInput.output.reason,
		);

		return {
			success: true,
			refund: {
				id: refund.id,
				registration_id: refund.registration_id,
				refund_amount: refund.refund_amount,
				refund_reason: refund.refund_reason,
				status: refund.status,
				requested_at: refund.requested_at,
			},
		};
	} catch (error) {
		return {
			success: false,
			error:
				error instanceof Error ? error.message : "Failed to process refund",
		};
	}
}

export async function getWorkshopRefundsForTest(
	session: Session,
	workshopId: string,
): Promise<ServiceResult<{ refunds: RefundWithUser[] }>> {
	try {
		const { refundService } = createWorkshopTestServices(session);
		const refunds = await refundService.getWorkshopRefunds(workshopId);
		return { success: true, refunds };
	} catch (error) {
		return {
			success: false,
			error: error instanceof Error ? error.message : "Failed to fetch refunds",
		};
	}
}

export async function updateWorkshopAttendanceForTest(
	session: Session,
	workshopId: string,
	attendanceUpdates: AttendanceUpdate[],
): Promise<ServiceResult<{ registrations: AttendanceResult[] }>> {
	const validatedInput = v.safeParse(AttendanceUpdatesSchema, {
		attendance_updates: attendanceUpdates,
	});

	if (!validatedInput.success) {
		return { success: false, issues: validatedInput.issues };
	}

	try {
		const { attendanceService } = createWorkshopTestServices(session);
		const registrations = await attendanceService.updateAttendance(
			workshopId,
			validatedInput.output.attendance_updates,
		);
		return { success: true, registrations };
	} catch (error) {
		return {
			success: false,
			error:
				error instanceof Error ? error.message : "Failed to update attendance",
		};
	}
}

export async function getWorkshopAttendanceForTest(
	session: Session,
	workshopId: string,
): Promise<ServiceResult<{ attendance: AttendanceResult[] }>> {
	try {
		const { attendanceService } = createWorkshopTestServices(session);
		const attendance =
			await attendanceService.getWorkshopAttendance(workshopId);
		return { success: true, attendance };
	} catch (error) {
		return {
			success: false,
			error:
				error instanceof Error ? error.message : "Failed to fetch attendance",
		};
	}
}

/**
 * Creates a test workshop with default values using direct database access
 */
export async function createTestWorkshop(
	_page: Page,
	overrides: CreateTestWorkshopOverrides = {},
): Promise<TestWorkshop> {
	const timestamp = Date.now();
	const randomSuffix = Math.random().toString(36).substring(2, 15);
	const supabase = getSupabaseServiceClient();

	const workshopStartDate = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days from now
	const workshopEndDate = new Date(
		workshopStartDate.getTime() + 2 * 60 * 60 * 1000,
	); // 2 hours later

	const defaultWorkshop = {
		title: `Test Workshop ${timestamp}-${randomSuffix}`,
		description: "Test workshop for E2E testing",
		location: "Test Location",
		start_date: workshopStartDate.toISOString(),
		end_date: workshopEndDate.toISOString(),
		max_capacity: 10,
		price_member: 2500, // 25.00 in cents
		price_non_member: 3500, // 35.00 in cents
		is_public: true,
		refund_days: 3,
		status: "published" as const,
		...overrides,
	};

	const { data: workshop, error } = await supabase
		.from("club_activities")
		.insert(defaultWorkshop)
		.select()
		.single();

	if (error) {
		throw new Error(`Failed to create workshop: ${error.message}`);
	}

	return {
		id: workshop.id,
		title: workshop.title || "",
		description: workshop.description || "",
		location: workshop.location || "",
		workshop_date: workshop.start_date,
		workshop_time: "14:00", // Default time
		max_capacity: workshop.max_capacity || 0,
		price_member: (workshop.price_member || 0) / 100, // Convert back to dollars
		price_non_member: (workshop.price_non_member || 0) / 100,
		is_public: workshop.is_public || false,
		refund_deadline_days: workshop.refund_days || 0,
	};
}

/**
 * Creates a test registration for a workshop using direct database access
 */
export async function createTestRegistration(
	_page: Page,
	workshopId: string,
	userId: string,
	overrides: CreateTestRegistrationOverrides = {},
): Promise<TestRegistration> {
	const supabase = getSupabaseServiceClient();

	const defaultRegistration: Database["public"]["Tables"]["club_activity_registrations"]["Insert"] =
		{
			club_activity_id: workshopId,
			member_user_id: userId,
			amount_paid: 2500, // 25.00 in cents
			status: "confirmed" as const,
			currency: "EUR",
			...overrides,
		};

	const { data: registration, error } = await supabase
		.from("club_activity_registrations")
		.insert(defaultRegistration)
		.select()
		.single();

	if (error) {
		throw new Error(`Failed to create registration: ${error.message}`);
	}

	return {
		id: registration.id,
		workshop_id: workshopId,
		member_user_id: registration.member_user_id || "",
		amount_paid: registration.amount_paid,
		status: registration.status,
		attendance_status: registration.attendance_status || undefined,
		attendance_notes: registration.attendance_notes || undefined,
	};
}

/**
 * Creates multiple test registrations for a workshop
 */
export async function createMultipleTestRegistrations(
	page: Page,
	workshopId: string,
	userIds: string[],
	overrides: CreateTestRegistrationOverrides = {},
): Promise<TestRegistration[]> {
	const registrations: TestRegistration[] = [];

	for (const userId of userIds) {
		const registration = await createTestRegistration(
			page,
			workshopId,
			userId,
			overrides,
		);
		registrations.push(registration);
	}

	return registrations;
}

/**
 * Creates a test refund for a registration
 */
export async function createTestRefund(
	_page: Page,
	session: Session,
	_workshopId: string,
	registrationId: string,
	reason: string = "Test refund reason",
): Promise<TestRefund> {
	const response = await processWorkshopRefundForTest(session, {
		registration_id: registrationId,
		reason,
	});

	if (!response.success) {
		throw new Error(response.error || "Failed to create refund");
	}

	return response.refund;
}

/**
 * Updates attendance for multiple registrations
 */
export async function updateTestAttendance(
	_page: Page,
	session: Session,
	workshopId: string,
	attendanceUpdates: Array<{
		registration_id: string;
		attendance_status: "attended" | "no_show" | "excused";
		notes?: string;
	}>,
): Promise<AttendanceResult[]> {
	const response = await updateWorkshopAttendanceForTest(
		session,
		workshopId,
		attendanceUpdates,
	);

	if (!response.success) {
		throw new Error(response.error || "Failed to update attendance");
	}

	return response.registrations;
}

/**
 * Fetches workshop attendance data
 */
export async function getWorkshopAttendance(
	_page: Page,
	session: Session,
	workshopId: string,
): Promise<AttendanceResult[]> {
	const response = await getWorkshopAttendanceForTest(session, workshopId);

	if (!response.success) {
		throw new Error(response.error || "Failed to fetch attendance");
	}

	return response.attendance;
}

/**
 * Fetches workshop refunds data
 */
export async function getWorkshopRefunds(
	_page: Page,
	session: Session,
	workshopId: string,
): Promise<RefundWithUser[]> {
	const response = await getWorkshopRefundsForTest(session, workshopId);

	if (!response.success) {
		throw new Error(response.error || "Failed to fetch refunds");
	}

	return response.refunds;
}

/**
 * Creates a workshop with past refund deadline for testing deadline validation
 */
export async function createPastDeadlineWorkshop(
	page: Page,
): Promise<TestWorkshop> {
	return createTestWorkshop(page, {
		start_date: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
		refund_days: 7,
	});
}

/**
 * Creates a finished workshop for testing refund restrictions
 */
export async function createFinishedWorkshop(
	page: Page,
): Promise<TestWorkshop> {
	return createTestWorkshop(page, {
		start_date: new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString(),
		end_date: new Date(Date.now() - 22 * 60 * 60 * 1000).toISOString(),
		status: "finished",
	});
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
			roles: new Set<RoleType>(["admin"]),
		}),
		createMember({
			email: `coordinator-test-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set<RoleType>(["workshop_coordinator"]),
		}),
		createMember({
			email: `member-test-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set<RoleType>(["member"]),
		}),
	]);

	return {
		admin: adminUser,
		coordinator: coordinatorUser,
		member: memberUser,
		async cleanUp() {
			await Promise.all([
				adminUser.cleanUp?.(),
				coordinatorUser.cleanUp?.(),
				memberUser.cleanUp?.(),
			]);
		},
	};
}

/**
 * Waits for an element to be visible with a custom timeout
 */
export async function waitForElement(
	page: Page,
	selector: string,
	timeout: number = 10000,
) {
	return page.waitForSelector(selector, { state: "visible", timeout });
}

/**
 * Waits for loading to complete (no loading spinners visible)
 */
export async function waitForLoadingComplete(
	page: Page,
	timeout: number = 15000,
) {
	await page.waitForSelector(".animate-spin", { state: "hidden", timeout });
}

/**
 * Fills a form field and waits for it to be updated
 */
export async function fillFormField(
	page: Page,
	selector: string,
	value: string,
) {
	await page.fill(selector, value);
	await page.waitForFunction(
		({ selector, value }) => {
			const element = document.querySelector(selector) as
				| HTMLInputElement
				| HTMLTextAreaElement;
			return element && element.value === value;
		},
		{ selector, value },
	);
}

/**
 * Selects an option from a dropdown and waits for it to be selected
 */
export async function selectDropdownOption(
	page: Page,
	selector: string,
	value: string,
) {
	await page.selectOption(selector, value);
	await page.waitForFunction(
		({ selector, value }) => {
			const element = document.querySelector(selector);
			return element && (element as HTMLSelectElement).value === value;
		},
		{ selector, value },
	);
}

/**
 * Clicks a button and waits for the action to complete
 */
export async function clickAndWait(
	page: Page,
	selector: string,
	waitForSelector?: string,
) {
	await page.click(selector);
	if (waitForSelector) {
		await page.waitForSelector(waitForSelector, { state: "visible" });
	}
}

/**
 * Validates that an API response has the expected success format
 */
export function validateApiResponse(
	data: Record<string, unknown>,
	expectedResource?: string,
) {
	if (!data.success) {
		throw new Error(`API request failed: ${data.error || "Unknown error"}`);
	}

	if (expectedResource && !data[expectedResource]) {
		throw new Error(
			`Expected resource '${expectedResource}' not found in response`,
		);
	}

	return data;
}

/**
 * Generates unique test data to avoid conflicts
 */
export function generateUniqueTestData(prefix: string = "test") {
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
