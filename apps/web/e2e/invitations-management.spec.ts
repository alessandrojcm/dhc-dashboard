import { expect, type Page, test } from "@playwright/test";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";
import {
	createMember,
	createUniqueEmail,
	setupInvitedUser,
} from "./setupFunctions";

const INVITATIONS_PATH = "/dashboard/members/invitations";

async function expectQueryParam(page: Page, key: string, value: string) {
	await expect
		.poll(() => new URL(page.url()).searchParams.get(key) ?? "")
		.toBe(value);
}

async function openInvitations(page: Page, expectedCount: number) {
	await gotoHydrated(page, INVITATIONS_PATH);
	await expect(
		page.getByRole("link", { name: "Invitations", exact: true }),
	).toHaveAttribute("aria-current", "page");
	await expect(
		page.getByRole("region", { name: "Invitation activity", exact: true }),
	).toHaveAttribute("aria-busy", "false");
	await expect(
		page.getByRole("searchbox", {
			name: "Search invitations",
			exact: true,
		}),
	).toBeVisible();
	await expect(
		page.getByText(`${expectedCount} invitations`, { exact: true }),
	).toBeVisible();
}

async function searchInvitations(page: Page, query: string) {
	const search = page.getByRole("searchbox", {
		name: "Search invitations",
		exact: true,
	});
	await search.fill(query);
	await page.getByRole("button", { name: "Search", exact: true }).click();
	await expectQueryParam(page, "inviteQ", query);
	await expect(page.getByText("1 invitation", { exact: true })).toBeVisible();
}

function invitationRow(page: Page, email: string) {
	return page.getByRole("row").filter({ hasText: email });
}

test.describe("Invitation management", () => {
	let admin: Awaited<ReturnType<typeof createMember>>;
	let expiredInvitation: Awaited<ReturnType<typeof setupInvitedUser>>;
	const invitations: Awaited<ReturnType<typeof setupInvitedUser>>[] = [];

	test.beforeAll(async () => {
		test.setTimeout(120_000);
		admin = await createMember({
			email: createUniqueEmail("invitation-management-admin"),
			roles: new Set(["admin"]),
		});

		const seededInvitations = await Promise.all(
			Array.from({ length: 25 }, async (_, index) => {
				return setupInvitedUser({
					email: createUniqueEmail("invitation-management", index),
					invitationStatus: index % 2 === 0 ? "pending" : "expired",
					useFakeCustomerId: true,
				});
			}),
		);
		invitations.push(...seededInvitations);
		expiredInvitation = invitations[1];
	});

	test.beforeEach(async ({ context, page }) => {
		await page.setViewportSize({ width: 1280, height: 720 });
		await loginAsUser(context, admin.email);
	});

	test.afterAll(async () => {
		await Promise.all([
			admin?.cleanUp().catch(console.error),
			...invitations.map((invitation) =>
				invitation.cleanUp().catch(console.error),
			),
		]);
	});

	test("displays and searches invitations", async ({ page }) => {
		await openInvitations(page, invitations.length);

		const search = page.getByRole("searchbox", {
			name: "Search invitations",
			exact: true,
		});
		await searchInvitations(page, expiredInvitation.email);
		const row = invitationRow(page, expiredInvitation.email);
		await expect(row).toBeVisible();
		await expect(row.getByText("expired", { exact: true })).toBeVisible();

		await page.getByRole("button", { name: "Clear search" }).click();
		await expectQueryParam(page, "inviteQ", "");
		await expect(search).toHaveValue("");
	});

	test("uses cursor pagination and preserves its page size", async ({
		page,
	}) => {
		await openInvitations(page, invitations.length);

		const pageSize = page.getByRole("button", {
			name: "Rows",
			exact: true,
		});
		await pageSize.click();
		await page.getByRole("option", { name: "25" }).click();
		await expectQueryParam(page, "invitePageSize", "25");
		await expect(pageSize).toContainText("25");

		await pageSize.click();
		await page.getByRole("option", { name: "10", exact: true }).click();
		await page.getByRole("button", { name: "Next" }).click();
		await expect
			.poll(() => new URL(page.url()).searchParams.get("inviteCursor") ?? "")
			.not.toBe("");
		await expectQueryParam(page, "invitePageSize", "10");
		await expect(page.getByRole("button", { name: "Previous" })).toBeEnabled();
	});

	test("does not carry member pagination into invitations", async ({
		page,
	}) => {
		await gotoHydrated(
			page,
			"/dashboard/members/directory?pageSize=25&q=member",
		);
		await page.getByRole("link", { name: "Invitations", exact: true }).click();
		await expect(page).toHaveURL(INVITATIONS_PATH);
		await expect(
			page.getByRole("searchbox", {
				name: "Search invitations",
				exact: true,
			}),
		).toBeVisible();
		expect(new URL(page.url()).searchParams.has("pageSize")).toBe(false);
		expect(new URL(page.url()).searchParams.has("q")).toBe(false);
		expect(page.url()).not.toContain("inviteCursor=");
	});

	test("resends an expired invitation", async ({ page }) => {
		await openInvitations(page, invitations.length);
		await searchInvitations(page, expiredInvitation.email);
		const row = invitationRow(page, expiredInvitation.email);
		await expect(row).toBeVisible();

		const responsePromise = page.waitForResponse(
			(response) =>
				response.url().endsWith("/api/invitations/resend") &&
				response.request().method() === "POST",
		);
		await row.getByLabel("Resend invitation email").click();
		expect((await responsePromise).ok()).toBe(true);
		await expect(page.getByText("Invitation email resent")).toBeVisible();
	});

	test("reports resend failures", async ({ page }) => {
		await page.route("**/api/invitations/resend", (route) =>
			route.fulfill({
				status: 500,
				contentType: "application/json",
				body: "{}",
			}),
		);
		await openInvitations(page, invitations.length);
		await searchInvitations(page, expiredInvitation.email);
		const row = invitationRow(page, expiredInvitation.email);
		await expect(row).toBeVisible();

		await row.getByLabel("Resend invitation email").click();
		await expect(
			page.getByText("Failed to resend invitation email"),
		).toBeVisible();
	});
});
