import { test, expect } from "@playwright/test";
import { loginAsUser } from "./auth";
import type { InventoryLoanSeed } from "./e2eApi";
import {
	createInventoryItem,
	createInventoryLoan,
	createInventoryStructure,
	createMember,
	createUniqueEmail,
} from "./setupFunctions";

// ALE-288 M3: the member request journey at explicit mobile width —
// browse → detail → request form in the same view, server validation
// surfaced inline, and duplicate protection without a 500.
test.use({ viewport: { width: 375, height: 812 } });

const tag = `request-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const makerRequest = `Requestable Feder ${tag}`;
const makerValidation = `Validation Mask ${tag}`;
const makerDuplicate = `Duplicate Sabre ${tag}`;
const requestNote = `E2E Thursday sparring ${tag}`;

let borrowerEmail = "";
const cleanups: Array<() => Promise<void>> = [];

test.describe("ALE-288 inventory member request", () => {
	test.beforeAll(async () => {
		const operator = await createMember({
			email: createUniqueEmail("inv-request-op"),
			roles: new Set(["member", "quartermaster"]),
		});
		cleanups.push(() => operator.cleanUp());

		const borrower = await createMember({
			email: createUniqueEmail("inv-request-borrower"),
		});
		cleanups.push(() => borrower.cleanUp());
		borrowerEmail = borrower.email;

		const structure = await createInventoryStructure({
			categoryName: `E2E Request Blades ${tag}`,
			definitions: [
				{
					label: "Maker",
					valueType: "text",
					required: true,
					identifyingPosition: 0,
				},
			],
			containerPath: [`E2E Request Cage ${tag}`, `E2E Request Rack ${tag}`],
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => structure.cleanUp());
		const makerDef = structure.definitionIds[0];
		const leaf = structure.containerIds[structure.containerIds.length - 1];

		const requestItem = await createInventoryItem({
			categoryId: structure.categoryId,
			containerId: leaf,
			values: { [makerDef]: makerRequest },
			actorId: operator.memberId,
		});
		cleanups.push(() => requestItem.cleanUp());

		const validationItem = await createInventoryItem({
			categoryId: structure.categoryId,
			containerId: leaf,
			values: { [makerDef]: makerValidation },
			actorId: operator.memberId,
		});
		cleanups.push(() => validationItem.cleanUp());

		const duplicateItem = await createInventoryItem({
			categoryId: structure.categoryId,
			containerId: leaf,
			values: { [makerDef]: makerDuplicate },
			actorId: operator.memberId,
		});
		cleanups.push(() => duplicateItem.cleanUp());
		// SAFETY: the requested preset returns the flat loan row matching
		// the declared inventoryLoan result type (mirrors the wrapper).
		const pending = (await createInventoryLoan({
			preset: "requested",
			itemId: duplicateItem.itemId,
			borrowerMemberId: borrower.memberId,
		})) as InventoryLoanSeed["result"] & { cleanUp(): Promise<void> };
		expect(pending.status).toBe("requested");
		cleanups.push(() => pending.cleanUp());
	});

	test.afterAll(async () => {
		// Best-effort in reverse creation order (loans first, then items,
		// structure, members). The per-run database is disposable; unique
		// fixture text keeps leftovers out of other specs.
		for (const cleanUp of cleanups.reverse()) {
			try {
				await cleanUp();
			} catch {
				/* best-effort: per-run database is disposable */
			}
		}
	});

	test("browse to detail to request stays in the same item view and lands in My Loans", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);
		await page.goto("/dashboard/equipment");
		await page.getByRole("link", { name: makerRequest }).click();
		await expect(page).toHaveURL(/\/dashboard\/equipment\/[^/]+$/);
		const sheet = page.getByRole("dialog");
		await expect(
			sheet.getByRole("heading", { name: "Request this item" }),
		).toBeVisible();

		await page.getByLabel(/Note/).fill(requestNote);
		await page.getByRole("button", { name: "Send request" }).click();

		await expect(
			page.getByText("Request sent. You'll receive the approved dates"),
		).toBeVisible();
		// Still the same item view — the form confirms inline, no redirect.
		await expect(page).toHaveURL(/\/dashboard\/equipment\/[^/]+$/);

		await page
			.locator("p", { hasText: "Request sent" })
			.getByRole("link", { name: "My loans" })
			.click();
		await expect(page).toHaveURL(/\/dashboard\/my-loans$/);
		await expect(page.getByRole("link", { name: makerRequest })).toBeVisible();
	});

	test("request dates use constrained calendar controls", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);
		await page.goto("/dashboard/equipment");
		await page.getByLabel("Search items").fill(makerValidation);
		await page.getByLabel("Search items").press("Enter");
		await page.getByRole("link", { name: makerValidation }).click();
		await expect(
			page
				.getByRole("dialog")
				.getByRole("heading", { name: "Request this item" }),
		).toBeVisible();

		await expect(page.locator('input[type="date"]')).toHaveCount(0);
		await page.getByRole("button", { name: "Collect" }).click();
		await expect(page.getByLabel("Select a month")).toBeVisible();
		await expect(page.getByLabel("Select a year")).toBeVisible();
		await page.keyboard.press("Escape");
		await page.getByRole("button", { name: "Return" }).click();
		await expect(
			page
				.locator('[data-slot="popover-content"][data-state="open"]')
				.getByLabel("Select a month"),
		).toBeVisible();
	});

	test("a second pending request for the same item is rejected without a 500", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);
		await page.goto("/dashboard/equipment");
		await page.getByLabel("Search items").fill(makerDuplicate);
		await page.getByLabel("Search items").press("Enter");
		await page.getByRole("link", { name: makerDuplicate }).click();
		await expect(
			page
				.getByRole("dialog")
				.getByRole("heading", { name: "Request this item" }),
		).toBeVisible();

		const [response] = await Promise.all([
			page.waitForResponse(
				(resp) =>
					resp.url().includes("/requests") &&
					resp.request().method() === "POST",
			),
			page.getByRole("button", { name: "Send request" }).click(),
		]);
		expect(response.status()).toBe(409);
		expect(response.status()).not.toBe(500);
		// Scoped to the request form: the toast echoes the same message.
		await expect(
			page
				.locator("form")
				.getByText("already have a pending request for this item"),
		).toBeVisible();
	});
});
