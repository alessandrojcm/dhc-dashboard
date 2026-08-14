import type {
	InventoryCategory,
	InventoryCategoryCreateRequest,
	InventoryContainer,
	InventoryContainerCreateRequest,
	InventoryItem,
	InventoryItemCreateRequest,
	InvitationCreateInvite,
	InvitationStatus,
	RegistrationStatus,
	SettingsItem,
	SettingsUpdateRequest,
	WaitlistEntryCreateRequest,
	WaitlistStatus,
	Workshop,
	WorkshopManagementRequest,
	WorkshopStatus,
} from "@dhc/api-client";

const API_BASE_URL = process.env.API_BASE_URL ?? "http://127.0.0.1:4000/api";
const HARNESS_KEY = process.env.E2E_HARNESS_KEY ?? "local-e2e-harness";

export type E2ERole =
	| "admin"
	| "committee_coordinator"
	| "member"
	| "president"
	| "quartermaster"
	| "workshop_coordinator";

type MemberSeed = {
	attrs: {
		email: string;
		roles?: E2ERole[];
		firstName?: string;
		lastName?: string;
		dateOfBirth?: string;
		phoneNumber?: string;
		pronouns?: string;
		gender?: string;
		medicalConditions?: string;
		customerId?: string;
	};
	result: {
		email: string;
		memberId: string;
		userId: string;
		profileId: string;
		customerId: string;
	};
};

type E2EWaitlistSeedRequest = Partial<WaitlistEntryCreateRequest> &
	Pick<WaitlistEntryCreateRequest, "email"> & {
		status?: WaitlistStatus;
		guardian?: {
			firstName?: string;
			lastName?: string;
			phoneNumber?: string;
		};
	};

type WaitlistSeed = {
	attrs: E2EWaitlistSeedRequest;
	result: {
		id: string;
		email: string;
		waitlistId: string;
		profileId: string;
	};
};

type E2EInvitationSeedRequest = Partial<InvitationCreateInvite> &
	Pick<InvitationCreateInvite, "email"> & {
		status?: InvitationStatus;
		invitationType?: string;
		customerId?: string;
	};

type InvitationSeed = {
	attrs: E2EInvitationSeedRequest;
	result: {
		invitationId: string;
		email: string;
		dateOfBirth: string;
		userId: string;
	};
};

export type E2EWorkshopSeedRequest = Omit<
	WorkshopManagementRequest,
	"announceDiscord" | "announceEmail" | "refundDays"
> & {
	announceDiscord?: boolean;
	announceEmail?: boolean;
	refundDays?: number | null;
	createdBy: string;
	status?: WorkshopStatus;
};

export type E2EWorkshopSeedResult = Pick<
	Workshop,
	| "id"
	| "title"
	| "description"
	| "location"
	| "startDate"
	| "endDate"
	| "maxCapacity"
	| "priceMember"
	| "priceNonMember"
	| "isPublic"
	| "refundDays"
	| "status"
>;

type WorkshopSeed = {
	attrs: E2EWorkshopSeedRequest;
	result: E2EWorkshopSeedResult;
};

type InventoryCategorySeed = {
	attrs: InventoryCategoryCreateRequest;
	result: InventoryCategory;
};

type InventoryContainerSeed = {
	attrs: InventoryContainerCreateRequest & { actorId: string };
	result: InventoryContainer;
};

type InventoryItemSeed = {
	attrs: InventoryItemCreateRequest & { actorId: string };
	result: InventoryItem;
};

export type E2ERegistrationSeedRequest = {
	workshopId: string;
	memberUserId: string;
	amountPaid?: number;
	currency?: string;
	status?: RegistrationStatus;
	attendanceStatus?: "pending" | "attended" | "no_show" | "excused";
	attendanceNotes?: string;
};

export type E2ERegistrationSeedResult = Required<
	Pick<E2ERegistrationSeedRequest, "workshopId" | "memberUserId">
> & {
	id: string;
	amountPaid: number;
	currency: string;
	status: RegistrationStatus;
	attendanceStatus: "pending" | "attended" | "no_show" | "excused";
	attendanceNotes: string | null;
};

type RegistrationSeed = {
	attrs: E2ERegistrationSeedRequest;
	result: E2ERegistrationSeedResult;
};

type WaitlistStatusSeed = {
	attrs: { isOpen: boolean };
	result: { isOpen: boolean };
};

type SettingSeed = {
	attrs: SettingsUpdateRequest & { key: string };
	result: Pick<SettingsItem, "key" | "value">;
};

type E2EScenarios = {
	member: MemberSeed;
	waitlist: WaitlistSeed;
	invitation: InvitationSeed;
	workshop: WorkshopSeed;
	inventoryCategory: InventoryCategorySeed;
	inventoryContainer: InventoryContainerSeed;
	inventoryItem: InventoryItemSeed;
	registration: RegistrationSeed;
	waitlistStatus: WaitlistStatusSeed;
	setting: SettingSeed;
};

export type E2EScenarioName = keyof E2EScenarios;
export type E2EFixtureType = Exclude<
	E2EScenarioName,
	"setting" | "waitlistStatus"
>;

export async function fetchE2EHarness(
	path: string,
	init: Omit<RequestInit, "headers">,
	retryConnectionReset = false,
) {
	for (let attempt = 0; ; attempt += 1) {
		try {
			return await fetch(`${API_BASE_URL}/e2e${path}`, {
				...init,
				headers: {
					"content-type": "application/json",
					"x-e2e-harness-key": HARNESS_KEY,
				},
			});
		} catch (error) {
			const cause = (error as { cause?: { code?: string } }).cause;
			if (!retryConnectionReset || attempt > 0 || cause?.code !== "ECONNRESET")
				throw error;
			await new Promise((resolve) => setTimeout(resolve, 50));
		}
	}
}

async function harnessRequest<T>(
	path: string,
	body: unknown,
	method: "PATCH" | "POST" = "POST",
): Promise<T> {
	const response = await fetchE2EHarness(path, {
		method,
		body: JSON.stringify(body),
	});

	if (!response.ok) {
		throw new Error(
			`E2E harness ${path} failed (${response.status}): ${await response.text()}`,
		);
	}

	return response.json() as Promise<T>;
}

export async function resetE2EState() {
	return harnessRequest<{ data: { reset: true } }>("/reset", {});
}

export async function seedE2EScenario<S extends E2EScenarioName>(
	scenario: S,
	attrs: E2EScenarios[S]["attrs"],
): Promise<E2EScenarios[S]["result"]> {
	const response = await harnessRequest<{
		data: E2EScenarios[S]["result"];
	}>(`/seed/${scenario}`, {
		attrs,
	});
	return response.data;
}

export async function deleteE2EFixture(type: E2EFixtureType, id: string) {
	await harnessRequest(`/fixtures/${type}/${id}`, {});
}

export async function auditInvitationAcceptance(id: string) {
	const response = await harnessRequest<{
		data: {
			sessionTokenCount: number;
			magicLinkTokenCount: number;
			principalCount: number;
			userProfileCount: number;
			memberRoleCount: number;
			discordIdentityCount: number;
			memberProfileCount: number;
			attemptCount: number;
			provisionedAttemptCount: number;
			completedAttemptCount: number;
			declinedAttemptCount: number;
			continuationCount: number;
			subjectClaimCount: number;
			stripeCustomerCount: number;
			monthlySubscriptionCount: number;
			annualSubscriptionCount: number;
		};
	}>(`/audit/invitation-acceptance/${id}`, {});
	return response.data;
}

export async function interruptNextOnboardingFinalization() {
	return harnessRequest<{ data: { armed: true } }>(
		"/onboarding/interrupt-next-finalization",
		{},
	);
}

type E2EUpdatableFixture =
	| "inventoryCategory"
	| "inventoryContainer"
	| "inventoryItem"
	| "registration"
	| "workshop";

export async function updateE2EFixture<T>(
	type: E2EUpdatableFixture,
	id: string,
	attrs: unknown,
): Promise<T> {
	const response = await harnessRequest<{ data: T }>(
		`/fixtures/${type}/${id}`,
		{ attrs },
		"PATCH",
	);
	return response.data;
}

export { API_BASE_URL, HARNESS_KEY };
