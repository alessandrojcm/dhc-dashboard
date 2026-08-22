import { expect, test } from "@playwright/test";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";

test.describe("Member Self-Management", () => {
	let testData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		testData = await createMember({
			email: `test-${Date.now()}@test.com`,
			createSubscription: true,
		});
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, testData.email);
	});
	test.afterAll(() => testData?.cleanUp());

	test("lands in the dashboard when using only member", async ({ page }) => {
		await gotoHydrated(page, "/dashboard");
		await expect(
			page.getByRole("heading", { name: "Dublin HEMA Club", level: 1 }),
		).toBeVisible();
		await expect(
			page.getByRole("navigation", { name: "Members sections" }),
		).toHaveCount(0);
	});

	test("should update member profile", async ({ page }) => {
		await gotoHydrated(page, `/dashboard/members/${testData.userId}`);
		await expect(
			page.getByRole("heading", { name: "My profile" }),
		).toBeVisible();
		await page.getByLabel(/first name/i).fill("Updated name");
		await page
			.getByLabel("Emergency contact", { exact: true })
			.fill("Test Contact");
		await page.getByLabel("Emergency contact phone").fill("0871234567");
		await page.getByLabel(/preferred weapon/i).click();
		await page.getByRole("option", { name: "Rapier" }).click();
		await page.getByRole("button", { name: /save changes/i }).click();

		await expect(page.getByText(/profile has been updated/i)).toBeVisible();
		await expect(page.getByLabel(/first name/i)).toHaveValue("Updated name");
		await expect(page.getByText(/Rapier/i).first()).toBeVisible();
		await expect(
			page
				.getByRole("button", {
					name: new RegExp(
						`Updated name.*${testData.last_name}.*${testData.email}`,
						"i",
					),
				})
				.first(),
		).toBeVisible();
	});

	test("it should show manage subscription button", async ({ page }) => {
		await gotoHydrated(page, `/dashboard/members/${testData.userId}`);
		const popup = page.waitForEvent("popup");
		await page
			.getByRole("button", { name: "Manage billing", exact: true })
			.click();
		const newPage = await popup;
		await expect(newPage).toHaveURL(/billing\.stripe\.com/);
	});

	test("it should not show other options when user is only member", async ({
		page,
	}) => {
		await gotoHydrated(page, `/dashboard/members/${testData.userId}`);
		expect(page.url()).toContain(`/dashboard/members/${testData.userId}`);
		const sidebar = page.getByTestId("sidebar");
		await expect(
			sidebar.getByRole("link", { name: "Home", exact: true }),
		).toBeVisible();
		await expect(
			sidebar.getByRole("link", { name: "My Workshops", exact: true }),
		).toBeVisible();
		await expect(
			sidebar.getByRole("link", { name: "Members", exact: true }),
		).toHaveCount(0);
	});
});

test.describe("Member Management - Admin", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let adminEmail: string;
	test.beforeAll(async () => {
		adminEmail = `admin-${Date.now()}@test.com`;
		adminData = await createMember({
			email: adminEmail,
			roles: new Set(["admin", "member"]),
		});
		memberData = await createMember({
			email: `member-${Date.now()}@test.com`,
			roles: new Set(["member"]),
			createSubscription: true,
			subscriptionPaymentMethod: "card",
		});
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, adminEmail);
	});
	test.afterAll(() =>
		Promise.all([adminData?.cleanUp(), memberData?.cleanUp()]),
	);

	test("it should show other options when user is admin", async ({ page }) => {
		await gotoHydrated(page, "/dashboard");
		await page
			.getByRole("button", { name: new RegExp(adminData.email, "i") })
			.first()
			.click();
		const profileLink = page
			.getByRole("menu")
			.getByRole("link", { name: "My Profile", exact: true });
		await expect(profileLink).toBeVisible();
		await profileLink.click();
		await expect(page).toHaveURL(`/dashboard/members/${adminData.userId}`);
		await expect(
			page.getByRole("heading", { name: "My profile", exact: true }),
		).toBeVisible();
	});

	test("admin should be able to navigate to a specific member profile", async ({
		page,
	}) => {
		await gotoHydrated(page, "/dashboard/members/directory");
		const memberEntry = () =>
			page.getByRole("article").filter({
				has: page.getByRole("link", { name: memberData.email }),
			});
		await memberEntry().getByRole("link", { name: "Edit member" }).click();
		await expect(
			page.getByRole("heading", {
				name: `Edit ${memberData.first_name} ${memberData.last_name}`,
			}),
		).toBeVisible();
		await expect(
			page.getByRole("link", { name: "Back to members" }),
		).toBeVisible();
		await expect(
			page.getByRole("navigation", { name: "Members sections" }),
		).toHaveCount(0);
		await page.getByLabel(/first name/i).fill("Updated name");
		await page
			.getByLabel("Emergency contact", { exact: true })
			.fill("Test Contact");
		await page.getByLabel("Emergency contact phone").fill("0871234567");
		await page.getByLabel(/preferred weapon/i).click();
		await page.getByRole("option", { name: "Rapier" }).click();
		await page.getByRole("button", { name: /save changes/i }).click();
		await expect(page.getByText(/profile has been updated/i)).toBeVisible();
		await expect(page.getByLabel(/first name/i)).toHaveValue("Updated name");
		await page.getByRole("link", { name: "Back to members" }).click();
		await expect(memberEntry()).toContainText("Updated name");
	});

	test("pause and resume update the member detail and directory without a reload", async ({
		page,
	}) => {
		await gotoHydrated(page, "/dashboard/members/directory");
		const memberEntry = () =>
			page.getByRole("article").filter({
				has: page.getByRole("link", { name: memberData.email }),
			});

		await expect(memberEntry()).toContainText("Active");
		await memberEntry().getByRole("link", { name: "Edit member" }).click();

		await page.getByRole("button", { name: "Pause subscription" }).click();
		const pauseDate = new Date();
		pauseDate.setDate(pauseDate.getDate() + 2);
		const pauseDateLabel = pauseDate.toLocaleDateString("en-US", {
			month: "long",
			day: "numeric",
			year: "numeric",
		});
		const pauseDialog = page.getByRole("dialog");
		await pauseDialog.getByRole("button", { name: "Resume Date" }).click();
		await page
			.getByRole("button", { name: new RegExp(pauseDateLabel) })
			.click();
		const pauseResponse = page.waitForResponse(
			(response) =>
				response.request().method() === "POST" &&
				response
					.url()
					.endsWith(`/members/${memberData.userId}/membership/pause`),
		);
		await pauseDialog
			.getByRole("button", { name: "Pause subscription" })
			.click();
		expect((await pauseResponse).status()).toBe(200);
		await expect(
			page.getByLabel("Membership settings").getByText(/Paused until/),
		).toBeVisible();

		await page.getByRole("link", { name: "Back to members" }).click();
		await expect(memberEntry()).toContainText("Paused");
		await memberEntry().getByRole("link", { name: "Edit member" }).click();

		const resumeResponse = page.waitForResponse(
			(response) =>
				response.request().method() === "POST" &&
				response
					.url()
					.endsWith(`/members/${memberData.userId}/membership/resume`),
		);
		await page.getByRole("button", { name: "Resume", exact: true }).click();
		expect((await resumeResponse).status()).toBe(200);
		await expect(
			page.getByLabel("Membership settings").getByText("Active", {
				exact: true,
			}),
		).toBeVisible();

		await page.getByRole("link", { name: "Back to members" }).click();
		await expect(memberEntry()).toContainText("Active");
	});
});

test.describe("Member management - cross member role check", () => {
	let memberOne: Awaited<ReturnType<typeof createMember>>;
	let memberTwo: Awaited<ReturnType<typeof createMember>>;
	let member1Email: string;
	let member2Email: string;

	test.beforeAll(async () => {
		member1Email = `member1-${Date.now()}@member.com`;
		member2Email = `member2-${Date.now()}@member.com`;
		memberTwo = await createMember({
			email: member2Email,
			roles: new Set(["member"]),
		});
		memberOne = await createMember({
			email: member1Email,
			roles: new Set(["member"]),
		});
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, member1Email);
	});
	test.afterAll(() =>
		Promise.all([memberOne?.cleanUp(), memberTwo?.cleanUp()]),
	);

	test("it should be redirected to its own profile if trying to access another users profile", async ({
		page,
	}) => {
		await gotoHydrated(page, `/dashboard/members/${memberTwo.userId}`);
		await expect(page.getByText(memberOne.first_name).first()).toBeVisible();
	});
});
