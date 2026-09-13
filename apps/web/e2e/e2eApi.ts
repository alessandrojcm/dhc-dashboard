import type {
	InventoryCategory,
	InventoryCategoryCreateRequest,
	InventoryContainer,
	InventoryContainerCreateRequest,
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
import * as v from "valibot";

const API_BASE_URL = process.env.API_BASE_URL ?? "http://127.0.0.1:4000/api";
const HARNESS_KEY = process.env.E2E_HARNESS_KEY ?? "local-e2e-harness";

type JsonScalar = string | number | boolean | null;
type JsonValue = JsonScalar | JsonValue[] | JsonObject;
type JsonObject = { [key: string]: JsonValue };

const connectionResetErrorSchema = v.object({
	cause: v.optional(
		v.object({
			code: v.optional(v.string()),
		}),
	),
});

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

type InventoryStructureDefinitionSeed = {
	label: string;
	valueType: "text" | "decimal" | "boolean" | "single_select";
	required?: boolean;
	identifyingPosition?: number | null;
	options?: Array<{ label: string; position?: number }>;
};

type InventoryStructureSeed = {
	attrs: {
		categoryName: string;
		categoryDescription?: string | null;
		definitions?: InventoryStructureDefinitionSeed[];
		containerPath?: string[];
		containerDescription?: string | null;
		actorId?: string;
	};
	result: {
		categoryId: string;
		categoryName: string;
		definitions: Array<{
			definitionId: string;
			label: string;
			valueType: "text" | "decimal" | "boolean" | "single_select";
			required: boolean;
			identifyingPosition: number | null;
			options: Array<{ optionId: string; label: string; position: number }>;
		}>;
		containers: Array<{
			containerId: string;
			name: string;
			parentContainerId: string | null;
			path: string[];
		}>;
	};
};

export type InventoryItemValue = string | number | boolean;

export type InventoryItemSeed = {
	attrs: {
		categoryId: string;
		containerId: string;
		values?: Record<string, InventoryItemValue>;
		notes?: string | null;
		actorId: string;
		withDuplicateLabel?: boolean;
		archived?: boolean;
		inMaintenance?: boolean;
	};
	result: {
		itemId: string;
		slug: string;
		label: string;
		categoryId: string;
		deletable: boolean;
	};
};

export type InventoryItemPairSeed = {
	attrs: InventoryItemSeed["attrs"] & { withDuplicateLabel: true };
	result: {
		items: InventoryItemSeed["result"][];
		deletable: boolean;
	};
};

export type InventoryLoanPreset =
	| "requested"
	| "approved"
	| "checkedOut"
	| "returned"
	| "rejected"
	| "cancelled"
	| "overdue"
	| "competingPair";

export type InventoryLoanSeed = {
	attrs: {
		preset: InventoryLoanPreset;
		itemId?: string;
		itemSlug?: string;
		borrowerMemberId?: string;
		borrowerMemberIds?: [string, string];
		startsOn?: string;
		dueOn?: string;
		note?: string | null;
		operatorActorId?: string;
		cancelledBy?: "member" | "operator";
		dueOffsetDays?: number;
		reminderState?: ReminderState;
	};
	result: {
		loanId: string;
		status:
			| "requested"
			| "approved"
			| "checked_out"
			| "returned"
			| "rejected"
			| "cancelled";
		overdue: boolean;
		itemId: string;
		slug: string;
		borrowerMemberId: string;
		startsOn: string;
		dueOn: string;
		containerPath: string | null;
		decidedBy: string | null;
		owedKind: "pre_due" | "overdue" | `overdue_week_${number}` | null;
		notificationKey: string | null;
	};
};

export type InventoryLoanPairSeed = {
	attrs: InventoryLoanSeed["attrs"] & {
		preset: "competingPair";
		borrowerMemberIds: [string, string];
	};
	result: {
		loans: InventoryLoanSeed["result"][];
		itemId: string;
	};
};

export type InventoryMaintenanceSeed = {
	attrs: {
		preset: "open" | "closed";
		itemId?: string;
		itemSlug?: string;
		reason: string;
		endNote?: string | null;
		operatorActorId: string;
	};
	result: {
		periodId: string;
		itemId: string;
		slug: string;
		open: boolean;
		reason: string;
		startedBy: string;
		endedBy: string | null;
	};
};

export type InventoryArchiveSeed = {
	attrs: {
		itemId?: string;
		itemSlug?: string;
		reason?: string | null;
		operatorActorId: string;
	};
	result: {
		itemId: string;
		slug: string;
		archived: boolean;
		archivedBy: string;
		catalogHidden: boolean;
		historyKept: boolean;
	};
};

export type ReminderState = "preDue" | "overdue" | "weekly";

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
	inventoryStructure: InventoryStructureSeed;
	// Pair seeds use the same scenario name with withDuplicateLabel: true;
	// narrow via Extract when the test needs items[]:
	// type PairResult = InventoryItemPairSeed["result"];
	inventoryItem: InventoryItemSeed;
	inventoryLoan: InventoryLoanSeed;
	// Pair seeds use the same scenario name with preset: "competingPair";
	// narrow via Extract when the test needs loans[]:
	// type PairResult = InventoryLoanPairSeed["result"];
	inventoryMaintenance: InventoryMaintenanceSeed;
	inventoryArchive: InventoryArchiveSeed;
	registration: RegistrationSeed;
	waitlistStatus: WaitlistStatusSeed;
	setting: SettingSeed;
};

export type E2EScenarioName = keyof E2EScenarios;
type ScenarioAttributes = E2EScenarios[E2EScenarioName]["attrs"];
type PartialScenarioAttributes = {
	[S in E2EScenarioName]: Partial<E2EScenarios[S]["attrs"]>;
}[E2EScenarioName];
type HarnessRequestBody =
	| { attrs: ScenarioAttributes | PartialScenarioAttributes }
	| { invitationId: string }
	| { empty?: never };
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
			const parsedError = v.safeParse(connectionResetErrorSchema, error);
			const cause = parsedError.success ? parsedError.output.cause : undefined;
			if (!retryConnectionReset || attempt > 0 || cause?.code !== "ECONNRESET")
				throw error;
			await new Promise((resolve) => setTimeout(resolve, 50));
		}
	}
}

async function harnessRequest<T>(
	path: string,
	body: HarnessRequestBody,
	method: "GET" | "PATCH" | "POST" = "POST",
): Promise<T> {
	const response = await fetchE2EHarness(path, {
		method,
		body: method === "GET" ? undefined : JSON.stringify(body),
	});

	if (!response.ok) {
		throw new Error(
			`E2E harness ${path} failed (${response.status}): ${await response.text()}`,
		);
	}

	const payload: T = await response.json();
	return payload;
}

export async function resetE2EState() {
	return harnessRequest<{ data: { reset: true } }>("/reset", {});
}

export async function startOnboardingIsolationProbe() {
	return harnessRequest<{ data: { started: true } }>(
		"/probes/onboarding-isolation",
		{},
	);
}

export type InvitationAcceptanceAssertion = {
	attempts: number;
	continuations: number;
	externalIdentities: number;
	magicLinksOrSessions: number;
	memberProfiles: number;
	obanJobs: number;
	principals: number;
	roles: number;
	stripeCustomerId: string | null;
	stripeInvocations: string[];
	stripeState: JsonObject;
	userProfiles: number;
};

export async function finishInvitationAcceptanceProbe(invitationId: string) {
	const response = await harnessRequest<{
		data: InvitationAcceptanceAssertion;
	}>(`/assertions/invitation-acceptance/${invitationId}`, {}, "GET");
	return response.data;
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
			attempts: Array<{
				id: string;
				status: string;
				lastError: string | null;
				operationActive: boolean;
			}>;
			recoveryJobs: Array<{
				id: number;
				state: string;
				args: JsonObject;
				attempt: number;
				scheduled_at: string;
				errors: JsonObject[];
			}>;
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

export async function interruptNextOnboardingFinalization(
	invitationId: string,
) {
	return harnessRequest<{ data: { armed: true } }>(
		"/onboarding/interrupt-next-finalization",
		{ invitationId },
	);
}

export async function clearOnboardingFinalizationInterruption(
	invitationId: string,
) {
	return harnessRequest<{ data: { cleared: true } }>(
		"/onboarding/clear-finalization-interruption",
		{ invitationId },
	);
}

type E2EUpdatableFixture =
	| "inventoryCategory"
	| "inventoryContainer"
	| "inventoryItem"
	| "inventoryStructure"
	| "registration"
	| "workshop";

export async function updateE2EFixture<S extends E2EUpdatableFixture>(
	type: S,
	id: string,
	attrs: Partial<E2EScenarios[S]["attrs"]>,
): Promise<E2EScenarios[S]["result"]> {
	const response = await harnessRequest<{
		data: E2EScenarios[S]["result"];
	}>(`/fixtures/${type}/${id}`, { attrs }, "PATCH");
	return response.data;
}

export { API_BASE_URL, HARNESS_KEY };
