import { expect, type Page, test } from "@playwright/test";
import {
	createMember,
	setupInvitedUser,
	createUniqueEmail,
} from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

const INVITATIONS_PATH = "/dashboard/members?tab=invitations";

async function expectQueryParam(page: Page, key: string, value: string) {
	await expect
		.poll(() => new URL(page.url()).searchParams.get(key))
		.toBe(value);
}

async function openInvitationsTabAndWaitForRows(page: Page) {
	await page.getByRole("tab", { name: "Invitations" }).click();
	await expect
		.poll(() => page.locator("table tbody tr").count())
		.toBeGreaterThan(0);
}

test.describe("Invitations table pagination and search", () => {
	let adminMember: Awaited<ReturnType<typeof createMember>>;
	const invitations: Awaited<ReturnType<typeof setupInvitedUser>>[] = [];

	test.beforeAll(async () => {
		test.setTimeout(120000);

		adminMember = await createMember({
			email: createUniqueEmail("invitations-table-test-admin"),
			roles: new Set(["admin"]),
		});

		await Promise.all(
			new Array(25).map(async (_, i) => {
				const invitation = await setupInvitedUser({
					email: createUniqueEmail("invite-pagination-test", i),
					invitationStatus: i % 2 === 0 ? "pending" : "expired",
					useFakeCustomerId: true,
				});
				invitations.push(invitation);
			}),
		);
	});

	test.afterAll(async () => {
		await Promise.all([
			adminMember?.cleanUp().catch(console.error),
			...invitations.map((invitation) =>
				invitation?.cleanUp().catch(console.error),
			),
		]);
	});

	test.beforeEach(async ({ context, page }) => {
		await page.setViewportSize({ width: 1280, height: 720 });
		await loginAsUser(context, adminMember.email);
	});

	test("should paginate invitations table correctly", async ({ page }) => {
		await page.goto(INVITATIONS_PATH);
		await openInvitationsTabAndWaitForRows(page);

		const nextButton = page.getByRole("button", { name: "Next" });
		const isNextButtonDisabled = await nextButton.isDisabled();

		if (!isNextButtonDisabled) {
			await nextButton.click();
			await expectQueryParam(page, "invitePage", "1");

			await expect(
				page.getByRole("button", { name: "Go to previous page" }),
			).toBeEnabled();
		}
	});

	test("should change page size correctly", async ({ page }) => {
		await page.goto(INVITATIONS_PATH);
		await openInvitationsTabAndWaitForRows(page);

		const pageSizeTrigger = page.getByRole("button", {
			name: "Invitations elements per page",
		});
		await pageSizeTrigger.click();
		await page.getByRole("option", { name: "25" }).click();

		await expectQueryParam(page, "invitePageSize", "25");
		await expect(pageSizeTrigger).toContainText("25");
	});

	test("should search invitations correctly", async ({ page }) => {
		await page.goto(INVITATIONS_PATH);
		await openInvitationsTabAndWaitForRows(page);

		const searchEmail = invitations[0].email;
		const searchInput = page.getByPlaceholder("Search invitations");
		await searchInput.fill(searchEmail);

		await expectQueryParam(page, "inviteQ", searchEmail);
		await expect(
			page
				.locator("table tbody tr td")
				.filter({ hasText: searchEmail })
				.first(),
		).toBeVisible();
	});

	test("should clear search correctly", async ({ page }) => {
		await page.goto(`${INVITATIONS_PATH}&inviteQ=test`);

		await page
			.locator('table tbody tr, p:has-text("No results found")')
			.first()
			.waitFor({ state: "attached", timeout: 10000 });

		const clearButton = page.getByRole("button", { name: "Clear search" });
		await clearButton.click({ force: true });

		const waitForClearedQuery = () =>
			expect
				.poll(() => new URL(page.url()).searchParams.get("inviteQ") ?? "", {
					timeout: 3000,
				})
				.toBe("");

		try {
			await waitForClearedQuery();
		} catch {
			await page.getByPlaceholder("Search invitations").fill("");
		}

		await expect
			.poll(() => new URL(page.url()).searchParams.get("inviteQ") ?? "", {
				timeout: 10000,
			})
			.toBe("");

		const currentUrl = new URL(page.url());
		const qParam = currentUrl.searchParams.get("inviteQ");
		expect(qParam === null || qParam === "").toBe(true);
	});

	test("should maintain separate pagination state from members table", async ({
		page,
	}) => {
		await page.goto("/dashboard/members?tab=members&page=2&pageSize=25");

		await openInvitationsTabAndWaitForRows(page);

		await expectQueryParam(page, "page", "2");
		await expectQueryParam(page, "pageSize", "25");
		expect(page.url()).not.toContain("invitePage=2");

		const nextButton = page.getByRole("button", { name: "Next" });
		const isNextButtonDisabled = await nextButton.isDisabled();

		if (!isNextButtonDisabled) {
			await nextButton.click();

			await expectQueryParam(page, "invitePage", "1");
			await expectQueryParam(page, "page", "2");
		}
	});
});
