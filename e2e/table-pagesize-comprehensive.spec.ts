import { faker } from "@faker-js/faker";
import { expect, type Page, test } from "@playwright/test";
import dayjs from "dayjs";
import {
	createMember,
	getSupabaseServiceClient,
	setupInvitedUser,
	createUniqueEmail,
} from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

const MEMBERS_PATH = "/dashboard/members?tab=members";
const INVITATIONS_PATH = "/dashboard/members?tab=invitations";
const WAITLIST_PATH = "/dashboard/beginners-workshop?tab=waitlist";

const RETRY_ATTEMPTS = 3;
type SetupInvitedUserOptions = NonNullable<
	Parameters<typeof setupInvitedUser>[0]
>;

async function setupInvitedUserWithRetry(
	options: Omit<SetupInvitedUserOptions, "email"> & {
		emailPrefix: string;
		index?: number;
	},
) {
	let lastError: unknown;

	for (let attempt = 0; attempt < RETRY_ATTEMPTS; attempt++) {
		try {
			return await setupInvitedUser({
				...options,
				email: createUniqueEmail(options.emailPrefix, options.index, attempt),
			});
		} catch (error) {
			lastError = error;
		}
	}

	throw lastError;
}

async function expectQueryParam(page: Page, key: string, value: string) {
	await expect
		.poll(() => new URL(page.url()).searchParams.get(key))
		.toBe(value);
}

async function openTabAndWaitForRows(page: Page, tabName: string) {
	await page.getByRole("tab", { name: tabName }).click();
	await expect
		.poll(() => page.locator("table tbody tr").count())
		.toBeGreaterThan(0);
}

async function expectPageSizeValue(
	page: Page,
	triggerLabel: string,
	value: string,
) {
	await expect(page.getByRole("button", { name: triggerLabel })).toContainText(
		value,
	);
}

test.describe("Comprehensive page size tests", () => {
	let adminMember: Awaited<ReturnType<typeof createMember>>;
	const testData = {
		members: [] as Awaited<ReturnType<typeof createMember>>[],
		waitlist: [] as { email: string }[],
		invitations: [] as Awaited<ReturnType<typeof setupInvitedUser>>[],
	};

	test.beforeAll(async () => {
		const supabase = getSupabaseServiceClient();

		// Create admin member
		adminMember = await createMember({
			email: createUniqueEmail("pagesize-test-admin"),
			roles: new Set(["admin"]),
			createSubscription: false,
		});

		await Promise.all([
			...new Array(25).map(async (_, i) => {
				testData.members.push(
					await createMember({
						email: createUniqueEmail("pagesize-member", i),
						roles: new Set(["member"]),
						createSubscription: false,
					}),
				);
			}),
			...new Array(25).map(async (_, i) => {
				const email = createUniqueEmail("pagesize-waitlist", i);

				await supabase.rpc("insert_waitlist_entry", {
					first_name: faker.person.firstName(),
					last_name: faker.person.lastName(),
					email: email,
					date_of_birth: dayjs().subtract(20, "years").toISOString(),
					pronouns: "they/them",
					gender: "non-binary",
					phone_number: faker.phone.number(),
					medical_conditions: "None",
					social_media_consent: "no",
				});

				testData.waitlist.push({ email });
			}),
			new Array(25).map(async (_, i) => {
				testData.invitations.push(
					await setupInvitedUser({
						email: createUniqueEmail("pagesize-invite", i),
						invitationStatus: i % 2 === 0 ? "pending" : "expired",
						useFakeCustomerId: true,
					}),
				);
			}),
		]);
	});

	test.afterAll(async () => {
		const supabase = getSupabaseServiceClient();
		await Promise.all([
			adminMember?.cleanUp().catch(console.error),
			supabase
				.from("waitlist")
				.delete()
				.in(
					"email",
					testData.waitlist.map((wl) => wl.email),
				),
			...testData.invitations.map((invitation) =>
				invitation?.cleanUp().catch(console.error),
			),
			...testData.members.map((member) =>
				member?.cleanUp().catch(console.error),
			),
		]);
	});

	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, adminMember.email);
	});

	test("members table: changing page size updates results", async ({
		page,
	}) => {
		await page.goto(MEMBERS_PATH);
		await openTabAndWaitForRows(page, "Members list");

		// Change to 25
		await page.goto(`${MEMBERS_PATH}&pageSize=25`);
		await openTabAndWaitForRows(page, "Members list");

		// Verify URL updated
		await expectQueryParam(page, "pageSize", "25");
		await expectPageSizeValue(page, "Members elements per page", "25");

		// Change to 50
		await page.goto(`${MEMBERS_PATH}&pageSize=50`);
		await openTabAndWaitForRows(page, "Members list");

		// Verify URL updated
		await expectQueryParam(page, "pageSize", "50");
		await expectPageSizeValue(page, "Members elements per page", "50");
	});

	test("waitlist table: changing page size updates results", async ({
		page,
	}) => {
		await page.goto(WAITLIST_PATH);
		await openTabAndWaitForRows(page, "Waitlist");

		// Change to 25
		await page.goto(`${WAITLIST_PATH}&pageSize=25`);
		await openTabAndWaitForRows(page, "Waitlist");

		// Verify URL updated
		await expectQueryParam(page, "pageSize", "25");
		await expectPageSizeValue(page, "Waitlist elements per page", "25");

		// Change to 50
		await page.goto(`${WAITLIST_PATH}&pageSize=50`);
		await openTabAndWaitForRows(page, "Waitlist");

		// Verify URL updated
		await expectQueryParam(page, "pageSize", "50");
		await expectPageSizeValue(page, "Waitlist elements per page", "50");
	});

	test("invitations table: changing page size updates results", async ({
		page,
	}) => {
		await page.goto(INVITATIONS_PATH);
		await openTabAndWaitForRows(page, "Invitations");

		// Change to 25
		await page.goto(`${INVITATIONS_PATH}&invitePageSize=25`);
		await openTabAndWaitForRows(page, "Invitations");

		// Verify URL updated with invitePageSize
		await expectQueryParam(page, "invitePageSize", "25");
		await expectPageSizeValue(page, "Invitations elements per page", "25");

		// Change to 50
		await page.goto(`${INVITATIONS_PATH}&invitePageSize=50`);
		await openTabAndWaitForRows(page, "Invitations");

		// Verify URL updated
		await expectQueryParam(page, "invitePageSize", "50");
		await expectPageSizeValue(page, "Invitations elements per page", "50");
	});

	test("members table: page size persists across pagination", async ({
		page,
	}) => {
		await page.goto(`${MEMBERS_PATH}&pageSize=25`);

		// Verify page size is 25
		await expectQueryParam(page, "pageSize", "25");

		// Go to next page
		const nextButton = page.getByRole("button", { name: "Next" });
		if (!(await nextButton.isDisabled())) {
			await nextButton.click();

			// Verify page size is still 25
			await expectQueryParam(page, "pageSize", "25");
			await expectQueryParam(page, "page", "1");
			await expectPageSizeValue(page, "Members elements per page", "25");
		}
	});

	test("waitlist table: page size persists across pagination", async ({
		page,
	}) => {
		await page.goto(`${WAITLIST_PATH}&pageSize=25`);

		// Verify page size is 25
		await expectQueryParam(page, "pageSize", "25");

		// Go to next page if available
		const nextButton = page.getByRole("button", { name: "Next" });
		if (!(await nextButton.isDisabled())) {
			await nextButton.click();

			// Verify page size is still 25
			await expectQueryParam(page, "pageSize", "25");
			await expectQueryParam(page, "page", "1");
			await expectPageSizeValue(page, "Waitlist elements per page", "25");
		}
	});

	test("invitations table: page size persists across pagination", async ({
		page,
	}) => {
		await page.goto(`${INVITATIONS_PATH}&invitePageSize=25`);

		// Verify page size is 25
		await expectQueryParam(page, "invitePageSize", "25");

		// Go to next page if available
		const nextButton = page.getByRole("button", { name: "Next" });
		if (!(await nextButton.isDisabled())) {
			await nextButton.click();

			// Verify page size is still 25
			await expectQueryParam(page, "invitePageSize", "25");
			await expectQueryParam(page, "invitePage", "1");
			await expectPageSizeValue(page, "Invitations elements per page", "25");
		}
	});

	test("invitations table: has independent page size from members table", async ({
		page,
	}) => {
		await page.goto(`${MEMBERS_PATH}&pageSize=25`);

		// Verify members table has pageSize=25
		await expectQueryParam(page, "pageSize", "25");

		// Click on invitations tab
		await page.getByRole("tab", { name: "Invitations" }).click();

		// Verify invitations table starts with default page size (10)
		// Should NOT have invitePageSize in URL yet
		const url = page.url();
		expect(url).toContain("pageSize=25"); // Members page size persists
		if (url.includes("invitePageSize")) {
			expect(url).toContain("invitePageSize=10"); // Default or explicitly set
		}

		// Change invitations page size to 50
		await page.goto(`${INVITATIONS_PATH}&pageSize=25&invitePageSize=50`);

		// Verify both page sizes are independent
		await expectQueryParam(page, "pageSize", "25"); // Members page size
		await expectQueryParam(page, "invitePageSize", "50"); // Invitations page size

		// Switch back to members tab
		await page.getByRole("tab", { name: "Members list" }).click();
		await openTabAndWaitForRows(page, "Members list");

		// Verify members table still has its own page size
		await expectQueryParam(page, "pageSize", "25");
		await expectPageSizeValue(page, "Members elements per page", "25");
	});
});
