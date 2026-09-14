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
let slugRequest = "";
let slugValidation = "";
let slugDuplicate = "";
const cleanups: Array<() => Promise<void>> = [];

function isoDate(offsetDays: number): string {
	return new Date(Date.now() + offsetDays * 86_400_000)
		.toISOString()
		.slice(0, 10);
}

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
		slugRequest = requestItem.slug;

		const validationItem = await createInventoryItem({
			categoryId: structure.categoryId,
			containerId: leaf,
			values: { [makerDef]: makerValidation },
			actorId: operator.memberId,
		});
		cleanups.push(() => validationItem.cleanUp());
		slugValidation = validationItem.slug;

		const duplicateItem = await createInventoryItem({
			categoryId: structure.categoryId,
			containerId: leaf,
			values: { [makerDef]: makerDuplicate },
			actorId: operator.memberId,
		});
		cleanups.push(() => duplicateItem.cleanUp());
		slugDuplicate = duplicateItem.slug;
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
		await expect(page).toHaveURL(
			new RegExp(`/dashboard/equipment/${slugRequest}$`),
		);
		await expect(
			page.getByRole("heading", { name: "Request this item" }),
		).toBeVisible();

		await page.getByLabel("Collect").fill(isoDate(0));
		await page.getByLabel("Return").fill(isoDate(7));
		await page.getByLabel(/Note/).fill(requestNote);
		await page.getByRole("button", { name: "Send request" }).click();

		await expect(
			page.getByText("Request sent. You'll receive the approved dates"),
		).toBeVisible();
		// Still the same item view — the form confirms inline, no redirect.
		await expect(page).toHaveURL(
			new RegExp(`/dashboard/equipment/${slugRequest}$`),
		);

		await page
			.locator("p", { hasText: "Request sent" })
			.getByRole("link", { name: "My loans" })
			.click();
		await expect(page).toHaveURL(/\/dashboard\/my-loans$/);
		await expect(page.getByRole("link", { name: makerRequest })).toBeVisible();
	});

	test("past dates and due-before-start show user-visible validation errors", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);
		await page.goto(`/dashboard/equipment/${slugValidation}`);
		await expect(
			page.getByRole("heading", { name: "Request this item" }),
		).toBeVisible();

		// The form carries native `min` guards; drop them so the server-side
		// date rule is what answers — that is the error the UI must show.
		await page
			.getByLabel("Collect")
			.evaluate((el) => el.removeAttribute("min"));
		await page.getByLabel("Return").evaluate((el) => el.removeAttribute("min"));

		await page.getByLabel("Collect").fill(isoDate(-2));
		await page.getByLabel("Return").fill(isoDate(7));
		await page.getByRole("button", { name: "Send request" }).click();
		const invalidResponse = await page.waitForResponse(
			(resp) =>
				resp.url().includes("/requests") && resp.request().method() === "POST",
		);
		expect(invalidResponse.status()).toBe(422);
		// Scoped to the request form: the toast echoes the same message.
		const requestForm = page.locator("form");
		await expect(
			requestForm.getByText("startsOn and dueOn must be dates today or later"),
		).toBeVisible();

		await page.getByLabel("Collect").fill(isoDate(5));
		await page.getByLabel("Return").fill(isoDate(2));
		await page.getByRole("button", { name: "Send request" }).click();
		await expect(
			requestForm.getByText("startsOn and dueOn must be dates today or later"),
		).toBeVisible();
	});

	test("a second pending request for the same item is rejected without a 500", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);
		await page.goto(`/dashboard/equipment/${slugDuplicate}`);
		await expect(
			page.getByRole("heading", { name: "Request this item" }),
		).toBeVisible();

		await page.getByLabel("Collect").fill(isoDate(0));
		await page.getByLabel("Return").fill(isoDate(7));
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
