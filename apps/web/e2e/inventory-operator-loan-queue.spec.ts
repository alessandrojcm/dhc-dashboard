import { expect, test, type Locator, type Page } from "@playwright/test";
import dayjs from "dayjs";
import { loginAsUser } from "./auth";
import { addClubDays, fetchE2EStatus } from "./e2eApi";
import {
	createInventoryItem,
	createInventoryLoan,
	createInventoryStructure,
	createMember,
	createOpenMaintenance,
	createUniqueEmail,
} from "./setupFunctions";

const tag = `operator-loans-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const cleanups: Array<() => Promise<void>> = [];
let operatorEmail = "";
let memberEmail = "";
let operatorId = "";
let borrowerId = "";
let categoryId = "";
let containerId = "";
let makerDefinitionId = "";
let clubToday = "";

function isoDate(offsetDays: number) {
	return addClubDays(clubToday, offsetDays);
}

async function pickDate(
	page: Page,
	panel: Locator,
	label: string,
	iso: string,
) {
	const date = dayjs(iso);
	const trigger = panel.getByRole("button", { name: label, exact: true });
	if ((await trigger.textContent())?.includes(date.format("MMMM D, YYYY")))
		return;
	await trigger.click();
	const calendar = page.locator(
		'[data-slot="popover-content"][data-state="open"]',
	);
	await calendar.getByLabel("Select a year").selectOption(date.format("YYYY"));
	await calendar.getByLabel("Select a month").selectOption(date.format("M"));
	await calendar
		.getByRole("button", { name: date.format("dddd, MMMM D,") })
		.click();
}

async function seedItem(label: string) {
	const item = await createInventoryItem({
		categoryId,
		containerId,
		values: { [makerDefinitionId]: label },
		actorId: operatorId,
	});
	cleanups.push(() => item.cleanUp());
	return item;
}

async function seedLoan(
	label: string,
	attrs: Omit<
		Parameters<typeof createInventoryLoan>[0],
		"itemId" | "borrowerMemberId" | "operatorActorId"
	>,
) {
	const item = await seedItem(label);
	const loan = await createInventoryLoan({
		...attrs,
		itemId: item.itemId,
		borrowerMemberId: borrowerId,
		operatorActorId: operatorId,
	});
	cleanups.push(() => loan.cleanUp());
	return { item, loan };
}

function bucket(page: Page, heading: string): Locator {
	return page.locator("section").filter({
		has: page.getByRole("heading", { name: heading, exact: true }),
	});
}

function itemCard(page: Page, label: string): Locator {
	return page.getByRole("article").filter({ hasText: label }).first();
}

async function openAction(page: Page, label: string, action: string) {
	await itemCard(page, label).getByRole("button", { name: action }).click();
	return page.getByRole("dialog").and(page.getByTestId("loan-action-panel"));
}

test.describe("ALE-286 operator loan queue", () => {
	test.beforeEach(async ({ page }) => {
		await page.setViewportSize({ width: 1280, height: 900 });
	});

	test.beforeAll(async () => {
		clubToday = (await fetchE2EStatus()).today;
		const operator = await createMember({
			email: createUniqueEmail("operator-loan-queue"),
			roles: new Set(["member", "quartermaster"]),
		});
		cleanups.push(() => operator.cleanUp());
		operatorEmail = operator.email;
		operatorId = operator.memberId;

		const borrower = await createMember({
			email: createUniqueEmail("operator-loan-borrower"),
		});
		cleanups.push(() => borrower.cleanUp());
		borrowerId = borrower.memberId;

		const member = await createMember({
			email: createUniqueEmail("operator-loan-member"),
		});
		cleanups.push(() => member.cleanUp());
		memberEmail = member.email;

		const structure = await createInventoryStructure({
			categoryName: `Operator loan blades ${tag}`,
			definitions: [
				{
					label: "Maker",
					valueType: "text",
					required: true,
					identifyingPosition: 0,
				},
			],
			containerPath: [`Operator cage ${tag}`, `Operator rack ${tag}`],
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => structure.cleanUp());
		categoryId = structure.categoryId;
		containerId = structure.containerIds.at(-1)!;
		makerDefinitionId = structure.definitionIds[0];
	});

	test.afterAll(async () => {
		for (const cleanUp of cleanups.reverse()) {
			try {
				await cleanUp();
			} catch {
				/* best-effort: the per-run database is disposable */
			}
		}
	});

	test("inventory operators can open the queue while ordinary members cannot", async ({
		browser,
	}) => {
		const operatorContext = await browser.newContext();
		const operatorPage = await operatorContext.newPage();
		await loginAsUser(operatorContext, operatorEmail);
		await operatorPage.goto("/dashboard/inventory/loans");
		await expect(
			operatorPage.getByRole("heading", { name: "Shared loan queue" }),
		).toBeVisible();
		await operatorContext.close();

		const memberContext = await browser.newContext();
		const memberPage = await memberContext.newPage();
		await loginAsUser(memberContext, memberEmail);
		await memberPage.goto("/dashboard/inventory/loans");
		await expect(memberPage).toHaveURL(/\/dashboard\/members\/[^/]+$/);
		await expect(
			memberPage.getByRole("heading", { name: "My profile" }),
		).toBeVisible();
		await expect(
			memberPage.getByRole("heading", { name: "Shared loan queue" }),
		).toHaveCount(0);
		await memberContext.close();
	});

	test("renders loan buckets and surfaces maintenance with items", async ({
		page,
		context,
	}) => {
		const requestedLabel = `Queue request ${tag}`;
		const approvedLabel = `Queue handover ${tag}`;
		const returnedLabel = `Queue return ${tag}`;
		const maintenanceLabel = `Queue maintenance ${tag}`;
		await seedLoan(requestedLabel, { preset: "requested" });
		await seedLoan(approvedLabel, { preset: "approved" });
		await seedLoan(returnedLabel, { preset: "checkedOut" });
		const maintenanceItem = await seedItem(maintenanceLabel);
		const maintenance = await createOpenMaintenance({
			itemId: maintenanceItem.itemId,
			reason: `Inspect queue item ${tag}`,
			operatorActorId: operatorId,
		});
		cleanups.push(() => maintenance.cleanUp());

		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/inventory/loans");
		for (const [heading, label] of [
			["Requests", requestedLabel],
			["Ready for handover", approvedLabel],
			["Returns and overdue", returnedLabel],
		] as const) {
			const section = bucket(page, heading);
			await expect(section.getByText(label)).toBeVisible();
			await expect(section.getByText("1", { exact: true })).toBeVisible();
		}
		const maintenanceBucket = page.getByTestId("open-maintenance-bucket");
		await expect(
			maintenanceBucket.getByRole("heading", { name: "Open maintenance" }),
		).toBeVisible();
		await expect(maintenanceBucket.getByText(maintenanceLabel)).toBeVisible();
		await expect(
			maintenanceBucket.getByText("1", { exact: true }),
		).toBeVisible();
		await expect(maintenanceBucket.getByText("Open item")).toBeVisible();
	});

	test("lays out all four queues as desktop board columns", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, operatorEmail);
		await page.setViewportSize({ width: 1440, height: 900 });
		await page.goto("/dashboard/inventory/loans");

		const board = page.getByTestId("loan-queue-board");
		await expect(board).toBeVisible();
		await expect(board).toHaveCSS(
			"grid-template-columns",
			/^\d+(?:\.\d+)?px \d+(?:\.\d+)?px \d+(?:\.\d+)?px \d+(?:\.\d+)?px$/,
		);
	});

	test("switches between loan queues in the compact mobile view", async ({
		page,
		context,
	}) => {
		const requestedLabel = `Mobile queue request ${tag}`;
		const returnedLabel = `Mobile queue return ${tag}`;
		await seedLoan(requestedLabel, { preset: "requested" });
		await seedLoan(returnedLabel, { preset: "checkedOut" });

		await loginAsUser(context, operatorEmail);
		await page.setViewportSize({ width: 390, height: 844 });
		await page.goto("/dashboard/inventory/loans");
		await expect(
			page.getByRole("heading", { name: "Shared loan queue" }),
		).toBeVisible();

		const selectorBar = page.getByTestId("mobile-loan-queue-selector");
		await expect(selectorBar).toHaveCSS("position", "sticky");
		await expect(bucket(page, "Requests")).toBeVisible();
		await expect(bucket(page, "Returns and overdue")).toBeHidden();

		await page.getByLabel("Queue view").selectOption("returns");
		await expect(page).toHaveURL(/\?view=returns$/);
		await expect(bucket(page, "Requests")).toBeHidden();
		await expect(bucket(page, "Returns and overdue")).toBeVisible();
		await expect(bucket(page, "Returns and overdue")).toContainText(
			returnedLabel,
		);

		await page.goBack();
		await expect(page).not.toHaveURL(/view=/);
		await expect(bucket(page, "Requests")).toBeVisible();
		await expect(bucket(page, "Requests")).toContainText(requestedLabel);
	});

	test("approves final dates and note, then checks out the refreshed handover", async ({
		page,
		context,
	}) => {
		const label = `Approve and checkout ${tag}`;
		const { loan } = await seedLoan(label, { preset: "requested" });
		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/inventory/loans");

		let panel = await openAction(page, label, "Review request");
		await pickDate(page, panel, "Approved start", isoDate(0));
		await pickDate(page, panel, "Approved due", isoDate(10));
		await panel.getByLabel("Decision note").fill(`Collection agreed ${tag}`);
		await panel.getByRole("button", { name: "Approve", exact: true }).click();
		await expect(page.getByText("Loan approved")).toBeVisible();
		await expect(bucket(page, "Requests").getByText(label)).toHaveCount(0);
		await expect(
			bucket(page, "Ready for handover").getByText(label),
		).toBeVisible();

		panel = await openAction(page, label, "Record handover");
		await panel.getByRole("button", { name: "Record checkout" }).click();
		await expect(page.getByText("Checkout recorded")).toBeVisible();
		await expect(
			bucket(page, "Returns and overdue").getByText(label),
		).toBeVisible();
		expect("loanId" in loan).toBe(true);
	});

	test("rejects a request and removes it from actionable work", async ({
		page,
		context,
	}) => {
		const label = `Reject request ${tag}`;
		await seedLoan(label, { preset: "requested" });
		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/inventory/loans");
		const panel = await openAction(page, label, "Review request");
		await panel.getByLabel("Decision note").fill(`Not suitable ${tag}`);
		await panel.getByRole("button", { name: "Reject" }).click();
		await expect(page.getByText("Request rejected")).toBeVisible();
		await expect(page.getByText(label)).toHaveCount(0);
	});

	test("surfaces a domain error when a handover mutation fails", async ({
		page,
		context,
	}) => {
		const label = `Blocked handover ${tag}`;
		await seedLoan(label, {
			preset: "approved",
			startsOn: isoDate(0),
			dueOn: isoDate(7),
		});
		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/inventory/loans");
		await page.route(
			"**/api/inventory/operator/loans/*/dates",
			async (route) => {
				await route.fulfill({
					status: 409,
					contentType: "application/json",
					body: JSON.stringify({
						errors: {
							detail: "The loan changed before these dates were saved.",
						},
					}),
				});
			},
		);
		const panel = await openAction(page, label, "Record handover");
		await pickDate(page, panel, "Due", isoDate(8));
		await panel.getByRole("button", { name: "Save dates" }).click();
		await expect(
			page.getByText("The loan changed before these dates were saved."),
		).toBeVisible();
	});

	test("visibly blocks checkout when an approved handover is not ready", async ({
		page,
		context,
	}) => {
		const label = `Non-ready handover ${tag}`;
		await seedLoan(label, {
			preset: "approved",
			checkoutReady: false,
		});
		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/inventory/loans");

		await expect(
			page.getByText(
				"Checkout is currently blocked. Edit the dates before retrying.",
			),
		).toBeVisible();
		const panel = await openAction(page, label, "Record handover");
		await expect(
			panel.getByRole("button", { name: "Record checkout" }),
		).toBeDisabled();
	});

	test("edits approved dates and cancels with an optional note", async ({
		page,
		context,
	}) => {
		const label = `Edit and cancel ${tag}`;
		await seedLoan(label, { preset: "approved" });
		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/inventory/loans");
		let panel = await openAction(page, label, "Record handover");
		await pickDate(page, panel, "Start", isoDate(0));
		await pickDate(page, panel, "Due", isoDate(12));
		await panel.getByRole("button", { name: "Save dates" }).click();
		await expect(page.getByText("Loan dates updated")).toBeVisible();

		await page.getByRole("button", { name: "Refresh" }).click();
		panel = await openAction(page, label, "Record handover");
		await panel
			.getByLabel("Cancellation note")
			.fill(`Borrower unavailable ${tag}`);
		await panel.getByRole("button", { name: "Cancel loan" }).click();
		await expect(page.getByText("Loan cancelled")).toBeVisible();
		await expect(page.getByText(label)).toHaveCount(0);
	});

	test("only edits the due date after checkout and records return", async ({
		page,
		context,
	}) => {
		const label = `Due edit and return ${tag}`;
		await seedLoan(label, { preset: "checkedOut" });
		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/inventory/loans");
		let panel = await openAction(page, label, "Record return");
		await expect(
			panel.getByRole("button", { name: "Start", exact: true }),
		).toHaveCount(0);
		await pickDate(page, panel, "Due date", isoDate(14));
		await panel.getByRole("button", { name: "Update due date" }).click();
		await expect(page.getByText("Loan dates updated")).toBeVisible();

		await page.getByRole("button", { name: "Refresh" }).click();
		panel = await openAction(page, label, "Record return");
		await panel.getByRole("button", { name: "Record return" }).click();
		await expect(page.getByText("Return recorded")).toBeVisible();
		await expect(page.getByText(label)).toHaveCount(0);
	});

	test("mobile action panel is fixed and exposes usable touch targets", async ({
		page,
		context,
	}) => {
		await page.setViewportSize({ width: 375, height: 812 });
		const label = `Mobile request ${tag}`;
		await seedLoan(label, { preset: "requested" });
		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/inventory/loans");
		const review = itemCard(page, label).getByRole("button", {
			name: "Review request",
		});
		const reviewBox = await review.boundingBox();
		expect(reviewBox?.height).toBeGreaterThanOrEqual(44);

		const panel = await openAction(page, label, "Review request");
		await expect(panel).toHaveCSS("position", "fixed");
		const panelBox = await panel.boundingBox();
		expect(panelBox?.x).toBeLessThanOrEqual(1);
		expect(panelBox?.width).toBeGreaterThanOrEqual(373);
		for (const name of ["Reject", "Approve"]) {
			const box = await panel
				.getByRole("button", { name, exact: true })
				.boundingBox();
			expect(box?.height).toBeGreaterThanOrEqual(48);
		}
	});
});
