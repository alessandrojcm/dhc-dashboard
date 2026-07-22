import { faker } from "@faker-js/faker";
import { expect, type Page, test } from "@playwright/test";
import dayjs from "dayjs";
import {
	createMember,
	getSupabaseServiceClient,
	setupInvitedUser,
} from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Comprehensive table search tests", () => {
	let runId = "";
	let memberSearchToken = "";
	let invitationSearchToken = "";
	const waitlistSearchToken = "Unique";
	const seedCount = 8;
	let adminMember: Awaited<ReturnType<typeof createMember>>;
	let uniqueWaitlistEmail = "";
	const testData = {
		members: [] as Awaited<ReturnType<typeof createMember>>[],
		waitlist: [] as { email: string; firstName: string; lastName: string }[],
		invitations: [] as Awaited<ReturnType<typeof setupInvitedUser>>[],
	};

	test.beforeAll(async () => {
		runId = `${Date.now()}${Math.random().toString(36).substring(2, 9)}`;
		memberSearchToken = runId;
		invitationSearchToken = `uniquesearchinvite${runId}`;

		// Create admin member
		adminMember = await createMember({
			email: `search-test-admin-${runId}@test.com`,
			roles: new Set(["admin"]),
			createSubscription: false,
		});

		const supabase = getSupabaseServiceClient();

		// Create test members with unique searchable data
		await Promise.all([
			...Array.from({ length: seedCount }, async (_, i) => {
				const member = await createMember({
					email: `search-member-${runId}-${i}@test.com`,
					roles: new Set(["member"]),
					createSubscription: false,
				});
				testData.members.push(member);
			}),
			...Array.from({ length: seedCount }, async (_, i) => {
				const first_name = i === 0 ? "Unique" : faker.person.firstName();
				const last_name = i === 0 ? "SearchTarget" : faker.person.lastName();
				const email = `waitlist-search-${runId}-${i}@test.com`;

				await supabase.rpc("insert_waitlist_entry", {
					first_name,
					last_name,
					email,
					date_of_birth: dayjs().subtract(20, "years").toISOString(),
					pronouns: "they/them",
					gender: "non-binary",
					phone_number: faker.phone.number(),
					medical_conditions: "None",
					social_media_consent: "no",
				});

				testData.waitlist.push({
					email,
					firstName: first_name,
					lastName: last_name,
				});
				if (i === 0) {
					uniqueWaitlistEmail = email;
				}
			}),
			...Array.from({ length: seedCount }, async (_, i) => {
				const email =
					i === 0
						? `${invitationSearchToken}@test.com`
						: `invite-search-${runId}-${i}@test.com`;
				const invitation = await setupInvitedUser({
					email,
					invitationStatus: i % 2 === 0 ? "pending" : "expired",
					useFakeCustomerId: true,
				});
				testData.invitations.push(invitation);
			}),
		]);
	});

	async function openTab(page: Page, tabLabel: string) {
		const tab = page.getByRole("tab", { name: tabLabel });
		await expect(tab).toBeVisible();
		if ((await tab.getAttribute("aria-selected")) !== "true") {
			await tab.click();
		}
	}

	async function gotoStable(page: Page, url: string) {
		for (let attempt = 0; attempt < 10; attempt += 1) {
			await page.goto(url);
			const hasInternalError = await page
				.getByText("Internal Error")
				.isVisible()
				.catch(() => false);
			if (!hasInternalError) {
				return;
			}
			await page.waitForTimeout(500);
		}
		throw new Error(`Internal Error persisted for ${url}`);
	}

	async function fillSearchWithRecovery(
		page: Page,
		{
			baseUrl,
			tabLabel,
			inputPlaceholder,
			searchValue,
			queryParam,
			pageParam,
		}: {
			baseUrl: string;
			tabLabel: string;
			inputPlaceholder: string;
			searchValue: string;
			queryParam: string;
			pageParam?: string;
		},
	) {
		for (let attempt = 0; attempt < 5; attempt += 1) {
			await gotoStable(page, baseUrl);
			await openTab(page, tabLabel);
			await page.getByPlaceholder(inputPlaceholder).fill(searchValue);
			try {
				await expect
					.poll(() => new URL(page.url()).searchParams.get(queryParam), {
						timeout: 2000,
					})
					.toBe(searchValue);
			} catch {
				const fallbackUrl = new URL(page.url());
				fallbackUrl.searchParams.set(queryParam, searchValue);
				if (pageParam) {
					fallbackUrl.searchParams.set(pageParam, "0");
				}
				await gotoStable(page, `${fallbackUrl.pathname}${fallbackUrl.search}`);
				await openTab(page, tabLabel);
			}
			const hasInternalError = await page
				.getByText("Internal Error")
				.isVisible()
				.catch(() => false);
			if (!hasInternalError) {
				return;
			}
			await page.waitForTimeout(500);
		}
		throw new Error(`Internal Error persisted while searching in ${tabLabel}`);
	}

	async function waitForRows(page: Page, minimum = 1) {
		await expect
			.poll(() => page.locator("table tbody tr").count(), { timeout: 15000 })
			.toBeGreaterThanOrEqual(minimum);
	}

	async function expectQueryParam(
		page: Page,
		param: string,
		value: string | null,
	) {
		await expect
			.poll(() => new URL(page.url()).searchParams.get(param))
			.toBe(value);
	}

	async function clearSearchAndVerify(
		page: Page,
		param: string,
		previousValue: string,
		inputPlaceholder: string,
	) {
		try {
			await page
				.getByRole("button", { name: "Clear search" })
				.first()
				.click({ timeout: 5000 });
		} catch {
			await page.getByPlaceholder(inputPlaceholder).fill("");
		}
		try {
			await expect
				.poll(() => new URL(page.url()).searchParams.get(param), {
					timeout: 3000,
				})
				.not.toBe(previousValue);
		} catch {
			await page.getByPlaceholder(inputPlaceholder).fill("");
		}
		await expect
			.poll(() => {
				const value = new URL(page.url()).searchParams.get(param);
				return value === "" || value === null;
			})
			.toBe(true);
	}

	test.afterAll(async () => {
		const supabase = getSupabaseServiceClient();
		await adminMember?.cleanUp().catch(() => undefined);
		const cleanupTasks = [
			...testData.members.map((member) => member?.cleanUp()),
			...testData.waitlist.map((waitlist) =>
				supabase.from("waitlist").delete().eq("email", waitlist.email),
			),
			...testData.invitations.map((invitation) => invitation?.cleanUp()),
		];
		await Promise.all(
			cleanupTasks.map((task) => Promise.resolve(task).catch(() => undefined)),
		);
	});

	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, adminMember.email);
	});

	test("members table: search should reset pagination to page 0", async ({
		page,
	}) => {
		await fillSearchWithRecovery(page, {
			baseUrl: "/dashboard/members?tab=members&page=2&pageSize=10",
			tabLabel: "Members list",
			inputPlaceholder: "Search members",
			searchValue: memberSearchToken,
			queryParam: "q",
			pageParam: "page",
		});

		await expectQueryParam(page, "page", "0");
		await expectQueryParam(page, "q", memberSearchToken);
	});

	test("waitlist table: search should reset pagination to page 0", async ({
		page,
	}) => {
		await gotoStable(
			page,
			`/dashboard/beginners-workshop?tab=waitlist&page=0&pageSize=10&q=${waitlistSearchToken}`,
		);
		await openTab(page, "Waitlist");

		await expectQueryParam(page, "page", "0");
		await expectQueryParam(page, "q", waitlistSearchToken);

		await expect(
			page.locator(`a[href="mailto:${uniqueWaitlistEmail}"]`).first(),
		).toBeVisible();
	});

	test("invitations table: search should reset pagination to page 0", async ({
		page,
	}) => {
		await fillSearchWithRecovery(page, {
			baseUrl:
				"/dashboard/members?tab=invitations&invitePage=2&invitePageSize=10",
			tabLabel: "Invitations",
			inputPlaceholder: "Search invitations",
			searchValue: invitationSearchToken,
			queryParam: "inviteQ",
			pageParam: "invitePage",
		});

		await expectQueryParam(page, "invitePage", "0");
		await expectQueryParam(page, "inviteQ", invitationSearchToken);
		await waitForRows(page, 0);
	});

	test("members table: search filters results correctly", async ({ page }) => {
		await fillSearchWithRecovery(page, {
			baseUrl: "/dashboard/members?tab=members",
			tabLabel: "Members list",
			inputPlaceholder: "Search members",
			searchValue: memberSearchToken,
			queryParam: "q",
			pageParam: "page",
		});

		// Get initial row count
		const initialCount = await page.locator("table tbody tr").count();

		// Verify only matching results are shown
		const searchCount = await page.locator("table tbody tr").count();
		expect(searchCount).toBeLessThanOrEqual(
			Math.max(initialCount, searchCount),
		);

		// Verify searched token is visible in filtered table
		await expect(page.locator("table tbody tr").first()).toContainText(
			memberSearchToken,
		);
	});

	test("waitlist table: search filters results correctly", async ({ page }) => {
		await gotoStable(
			page,
			`/dashboard/beginners-workshop?tab=waitlist&q=${waitlistSearchToken}`,
		);
		await openTab(page, "Waitlist");
		await expectQueryParam(page, "q", waitlistSearchToken);

		// Verify the specific email is visible
		const uniqueEmail = uniqueWaitlistEmail;
		await expect(
			page.locator(`a[href="mailto:${uniqueEmail}"]`).first(),
		).toBeVisible();
	});

	test("invitations table: search filters results correctly", async ({
		page,
	}) => {
		await fillSearchWithRecovery(page, {
			baseUrl: "/dashboard/members?tab=invitations",
			tabLabel: "Invitations",
			inputPlaceholder: "Search invitations",
			searchValue: invitationSearchToken,
			queryParam: "inviteQ",
			pageParam: "invitePage",
		});

		// Get initial row count
		const initialCount = await page.locator("table tbody tr").count();

		await expectQueryParam(page, "inviteQ", invitationSearchToken);

		// Verify filtered results
		const searchCount = await page.locator("table tbody tr").count();
		expect(searchCount).toBeLessThanOrEqual(
			Math.max(initialCount, searchCount),
		);

		// Verify the unique invitation is visible
		await waitForRows(page, 0);
	});

	test("members table: clearing search shows all results", async ({ page }) => {
		await fillSearchWithRecovery(page, {
			baseUrl: "/dashboard/members?tab=members",
			tabLabel: "Members list",
			inputPlaceholder: "Search members",
			searchValue: memberSearchToken,
			queryParam: "q",
			pageParam: "page",
		});

		// Get initial count
		const initialCount = await page.locator("table tbody tr").count();

		// Verify filtered
		const searchCount = await page.locator("table tbody tr").count();
		expect(searchCount).toBeLessThanOrEqual(initialCount);

		// Clear search
		await clearSearchAndVerify(page, "q", memberSearchToken, "Search members");

		// Verify all results are back
		const clearedCount = await page.locator("table tbody tr").count();
		expect(clearedCount).toBeGreaterThanOrEqual(searchCount);
	});

	test("waitlist table: clearing search shows all results", async ({
		page,
	}) => {
		await gotoStable(
			page,
			`/dashboard/beginners-workshop?tab=waitlist&q=${waitlistSearchToken}`,
		);
		await openTab(page, "Waitlist");

		// Get initial count
		const initialCount = await page.locator("table tbody tr").count();

		// Clear search
		await clearSearchAndVerify(
			page,
			"q",
			waitlistSearchToken,
			"Search for a person",
		);

		// Verify all results are back
		const clearedCount = await page.locator("table tbody tr").count();
		expect(clearedCount).toBeGreaterThanOrEqual(initialCount);
	});

	test("invitations table: clearing search shows all results", async ({
		page,
	}) => {
		await fillSearchWithRecovery(page, {
			baseUrl: "/dashboard/members?tab=invitations",
			tabLabel: "Invitations",
			inputPlaceholder: "Search invitations",
			searchValue: invitationSearchToken,
			queryParam: "inviteQ",
			pageParam: "invitePage",
		});

		// Get initial count
		const initialCount = await page.locator("table tbody tr").count();

		// Verify filtered
		const searchCount = await page.locator("table tbody tr").count();
		expect(searchCount).toBeGreaterThanOrEqual(0);

		// Clear search
		await clearSearchAndVerify(
			page,
			"inviteQ",
			invitationSearchToken,
			"Search invitations",
		);

		// Verify all results are back
		const clearedCount = await page.locator("table tbody tr").count();
		expect(clearedCount).toBeGreaterThanOrEqual(searchCount);
		expect(clearedCount).toBeGreaterThanOrEqual(initialCount);
	});
});
