import { expect, test } from "@playwright/test";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./auth";

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

	test("should navigate to member profile when using only member", async ({
		page,
	}) => {
		await page.goto("/dashboard");
		await expect(page.getByText(/member information/i)).toBeVisible();
	});

	test("should update member profile", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page.getByText(/member information/i)).toBeVisible();
		await page.getByLabel(/first name/i).fill("Updated name");
		await page.getByLabel("Next of Kin", { exact: true }).fill("Test Contact");
		await page.getByLabel("Next of Kin Phone Number").fill("0871234567");
		await page.getByLabel(/preferred weapon/i).click();

		await page.getByRole("option", { name: "Rapier" }).click();
		await page.getByRole("button", { name: /save changes/i }).click();

		await expect(page.getByText(/profile has been updated/i)).toBeVisible();
		await page.reload();
		await expect(page.getByLabel(/first name/i)).toHaveValue("Updated name");
		await expect(page.getByText(/Rapier/i).first()).toBeVisible();
	});

	test("it should show manage subscription button", async ({ page }) => {
		await page.goto("/dashboard");
		await page.getByText(/manage payment settings/i).click();
		const newPage = await page.waitForEvent("popup");
		await expect(newPage).toHaveURL(/billing\.stripe\.com/);
	});

	test("it should not show other options when user is only member", async ({
		page,
	}) => {
		await page.goto("/dashboard");
		expect(page.url()).toContain(`/dashboard/members/${testData.userId}`);
		await expect(page.getByTestId("sidebar")).toHaveText("My Workshops");
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
		});
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, adminEmail);
	});
	test.afterAll(() =>
		Promise.all([adminData?.cleanUp(), memberData?.cleanUp()]),
	);

	test("it should show other options when user is admin", async ({ page }) => {
		await page.goto("/dashboard");
		await page
			.getByRole("button", { name: new RegExp(adminData.email, "i") })
			.first()
			.click();
		await page.getByRole("link", { name: "My Profile" }).click();
		await expect(page.getByTestId("sidebar")).not.toHaveText("");
	});

	test("admin should be able to navigate to a specific member profile", async ({
		page,
	}) => {
		await page.goto(`/dashboard/members/${memberData.userId}`);
		await page.getByLabel(/first name/i).fill("Updated name");
		await page.getByLabel("Next of Kin", { exact: true }).fill("Test Contact");
		await page.getByLabel("Next of Kin Phone Number").fill("0871234567");
		await page.getByLabel(/preferred weapon/i).click();
		await page.getByRole("option", { name: "Rapier" }).click();
		await page.getByRole("button", { name: /save changes/i }).click();
		await expect(page.getByText(/profile has been updated/i)).toBeVisible();
		await page.reload();
		await expect(page.getByLabel(/first name/i)).toHaveValue("Updated name");
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
		await page.goto(`/dashboard/members/${memberTwo.userId}`);
		await expect(page.getByText(memberOne.first_name).first()).toBeVisible();
	});
});
