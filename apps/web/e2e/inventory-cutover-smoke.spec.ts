import { test, expect, type Page } from "@playwright/test";
import { loginAsUser } from "./auth";
import {
	API_BASE_URL,
	fetchE2EStatus,
	type InventoryLoanPairSeed,
	type InventoryLoanSeed,
	runLoanReminders,
} from "./e2eApi";
import {
	createInventoryItem,
	createInventoryLoan,
	createInventoryStructure,
	createMember,
	createUniqueEmail,
} from "./setupFunctions";

// ALE-288 S5: cutover smoke at explicit mobile width. The minimum real
// browser/API journey (browse → request → cancel) plus the operator
// lifecycle driven through the generated API operations in the
// authenticated browser request context — there is no operator UI, so the
// browser asserts member-visible outcomes after each operator transition.
// No raw SQL, no harness bypass: every transition goes through a public
// route with a real session cookie.
test.use({ viewport: { width: 375, height: 812 } });

type SeededLoan = InventoryLoanSeed["result"] & { cleanUp(): Promise<void> };

async function apiStatus(
	page: Page,
	path: string,
	data: Record<string, string> = {},
): Promise<number> {
	const response = await page.request.post(`${API_BASE_URL}${path}`, {
		data,
	});
	return response.status();
}

test.describe("ALE-288 inventory cutover smoke", () => {
	test("member browse, request and cancel loop", async ({ page, context }) => {
		const tag = `smoke-loop-${Date.now().toString(36)}`;
		const maker = `Smoke Loop Feder ${tag}`;
		const cleanups: Array<() => Promise<void>> = [];
		try {
			const operator = await createMember({
				email: createUniqueEmail("inv-smoke-loop-op"),
				roles: new Set(["member", "quartermaster"]),
			});
			cleanups.push(() => operator.cleanUp());
			const borrower = await createMember({
				email: createUniqueEmail("inv-smoke-loop-member"),
			});
			cleanups.push(() => borrower.cleanUp());

			const structure = await createInventoryStructure({
				categoryName: `E2E Smoke Loop ${tag}`,
				definitions: [
					{
						label: "Maker",
						valueType: "text",
						required: true,
						identifyingPosition: 0,
					},
				],
				containerPath: [`E2E Smoke Cage ${tag}`, `E2E Smoke Rack ${tag}`],
				operatorActorId: operator.memberId,
			});
			cleanups.push(() => structure.cleanUp());
			const makerDef = structure.definitionIds[0];
			const leaf = structure.containerIds[structure.containerIds.length - 1];
			const item = await createInventoryItem({
				categoryId: structure.categoryId,
				containerId: leaf,
				values: { [makerDef]: maker },
				actorId: operator.memberId,
			});
			cleanups.push(() => item.cleanUp());

			await loginAsUser(context, borrower.email);
			await page.goto("/dashboard/equipment");
			await page.getByRole("link", { name: maker }).click();
			await expect(page).toHaveURL(/\/dashboard\/equipment\/[^/]+$/);
			await expect(page.getByRole("dialog")).toBeVisible();

			await page.getByRole("button", { name: "Send request" }).click();
			await expect(
				page.getByText("Request sent. You'll receive the approved dates"),
			).toBeVisible();

			await page.goto("/dashboard/my-loans");
			await page.getByRole("link", { name: maker }).click();
			await expect(
				page.getByRole("heading", { name: "Cancel this loan" }),
			).toBeVisible();
			await page.getByRole("button", { name: "Cancel loan" }).click();
			await expect(
				page.getByText("Loan cancelled — the item is available again.", {
					exact: true,
				}),
			).toBeVisible();
			await expect(page.getByText("cancelled").first()).toBeVisible();
		} finally {
			for (const cleanUp of cleanups.reverse()) {
				try {
					await cleanUp();
				} catch {
					/* best-effort: per-run database is disposable */
				}
			}
		}
	});

	test("operator approve, checkout and return surface member-visible outcomes", async ({
		page,
		context,
	}) => {
		const tag = `smoke-lifecycle-${Date.now().toString(36)}`;
		const maker = `Smoke Lifecycle Feder ${tag}`;
		const cleanups: Array<() => Promise<void>> = [];
		try {
			const operator = await createMember({
				email: createUniqueEmail("inv-smoke-life-op"),
				roles: new Set(["member", "quartermaster"]),
			});
			cleanups.push(() => operator.cleanUp());
			const borrower = await createMember({
				email: createUniqueEmail("inv-smoke-life-member"),
			});
			cleanups.push(() => borrower.cleanUp());

			const structure = await createInventoryStructure({
				categoryName: `E2E Smoke Lifecycle ${tag}`,
				definitions: [
					{
						label: "Maker",
						valueType: "text",
						required: true,
						identifyingPosition: 0,
					},
				],
				containerPath: [`E2E Smoke Cage ${tag}`, `E2E Smoke Rack ${tag}`],
				operatorActorId: operator.memberId,
			});
			cleanups.push(() => structure.cleanUp());
			const makerDef = structure.definitionIds[0];
			const leaf = structure.containerIds[structure.containerIds.length - 1];
			const item = await createInventoryItem({
				categoryId: structure.categoryId,
				containerId: leaf,
				values: { [makerDef]: maker },
				actorId: operator.memberId,
			});
			cleanups.push(() => item.cleanUp());
			// SAFETY: every non-pair preset returns the flat loan row matching
			// the declared inventoryLoan result type (mirrors the wrapper).
			const loan = (await createInventoryLoan({
				preset: "requested",
				itemId: item.itemId,
				borrowerMemberId: borrower.memberId,
			})) as SeededLoan;
			cleanups.push(() => loan.cleanUp());

			// Approve as the operator through the public operator route.
			await loginAsUser(context, operator.email);
			const approved = await apiStatus(
				page,
				`/inventory/operator/loans/${loan.loanId}/approve`,
			);
			expect(approved).toBe(200);

			// The borrower learns the collection location only now.
			await loginAsUser(context, borrower.email);
			await page.goto("/dashboard/my-loans");
			await page.getByRole("link", { name: maker }).click();
			await expect(
				page.getByRole("dialog").getByText(/Collect from/),
			).toBeVisible();

			// Checkout hands the item over; the member cannot cancel anymore.
			await loginAsUser(context, operator.email);
			const checkedOut = await apiStatus(
				page,
				`/inventory/operator/loans/${loan.loanId}/checkout`,
			);
			expect(checkedOut).toBe(200);

			await loginAsUser(context, borrower.email);
			await page.goto("/dashboard/my-loans");
			await page.getByRole("link", { name: maker }).click();
			const checkedOutSheet = page.getByRole("dialog");
			await expect(
				checkedOutSheet.getByText("hand it back to a quartermaster"),
			).toBeVisible();
			await expect(
				checkedOutSheet.getByRole("button", { name: "Cancel loan" }),
			).toHaveCount(0);

			// Return closes custody; the record stays readable as returned.
			await loginAsUser(context, operator.email);
			const returned = await apiStatus(
				page,
				`/inventory/operator/loans/${loan.loanId}/return`,
			);
			expect(returned).toBe(200);

			await loginAsUser(context, borrower.email);
			await page.goto("/dashboard/my-loans");
			await page.getByRole("link", { name: maker }).click();
			await expect(
				page.getByRole("dialog").getByText("returned").first(),
			).toBeVisible();
		} finally {
			for (const cleanUp of cleanups.reverse()) {
				try {
					await cleanUp();
				} catch {
					/* best-effort: per-run database is disposable */
				}
			}
		}
	});

	test("approving one request rejects its competitor with the system note", async ({
		page,
		context,
	}) => {
		const tag = `smoke-compete-${Date.now().toString(36)}`;
		const maker = `Smoke Contested Feder ${tag}`;
		const cleanups: Array<() => Promise<void>> = [];
		try {
			const operator = await createMember({
				email: createUniqueEmail("inv-smoke-comp-op"),
				roles: new Set(["member", "quartermaster"]),
			});
			cleanups.push(() => operator.cleanUp());
			const winner = await createMember({
				email: createUniqueEmail("inv-smoke-comp-winner"),
			});
			cleanups.push(() => winner.cleanUp());
			const loser = await createMember({
				email: createUniqueEmail("inv-smoke-comp-loser"),
			});
			cleanups.push(() => loser.cleanUp());

			const structure = await createInventoryStructure({
				categoryName: `E2E Smoke Compete ${tag}`,
				definitions: [
					{
						label: "Maker",
						valueType: "text",
						required: true,
						identifyingPosition: 0,
					},
				],
				containerPath: [`E2E Smoke Cage ${tag}`, `E2E Smoke Rack ${tag}`],
				operatorActorId: operator.memberId,
			});
			cleanups.push(() => structure.cleanUp());
			const makerDef = structure.definitionIds[0];
			const leaf = structure.containerIds[structure.containerIds.length - 1];
			const item = await createInventoryItem({
				categoryId: structure.categoryId,
				containerId: leaf,
				values: { [makerDef]: maker },
				actorId: operator.memberId,
			});
			cleanups.push(() => item.cleanUp());
			// SAFETY: preset "competingPair" returns the pair shape with no
			// flat loanId (mirrors the wrapper's own narrowing).
			const pair = (await createInventoryLoan({
				preset: "competingPair",
				itemId: item.itemId,
				borrowerMemberIds: [winner.memberId, loser.memberId],
			})) as InventoryLoanPairSeed["result"] & {
				cleanUp(): Promise<void>;
			};
			expect(pair.loans).toHaveLength(2);
			cleanups.push(() => pair.cleanUp());

			await loginAsUser(context, operator.email);
			const approved = await apiStatus(
				page,
				`/inventory/operator/loans/${pair.loans[0].loanId}/approve`,
			);
			expect(approved).toBe(200);

			await loginAsUser(context, winner.email);
			await page.goto("/dashboard/my-loans");
			await page.getByRole("link", { name: maker }).click();
			await expect(
				page.getByRole("dialog").getByText(/Collect from/),
			).toBeVisible();

			await loginAsUser(context, loser.email);
			await page.goto("/dashboard/my-loans");
			await page.getByRole("link", { name: maker }).click();
			const rejectedSheet = page.getByRole("dialog");
			await expect(rejectedSheet.getByText("rejected").first()).toBeVisible();
			await expect(
				rejectedSheet.getByText(
					"Rejected automatically: another request for this item was approved.",
				),
			).toBeVisible();
		} finally {
			for (const cleanUp of cleanups.reverse()) {
				try {
					await cleanUp();
				} catch {
					/* best-effort: per-run database is disposable */
				}
			}
		}
	});

	test("maintenance and archive interlocks refuse a live loan, then archive wins after return", async ({
		page,
		context,
	}) => {
		const tag = `smoke-interlock-${Date.now().toString(36)}`;
		const maker = `Smoke Interlock Feder ${tag}`;
		const cleanups: Array<() => Promise<void>> = [];
		try {
			const operator = await createMember({
				email: createUniqueEmail("inv-smoke-lock-op"),
				roles: new Set(["member", "quartermaster"]),
			});
			cleanups.push(() => operator.cleanUp());
			const borrower = await createMember({
				email: createUniqueEmail("inv-smoke-lock-member"),
			});
			cleanups.push(() => borrower.cleanUp());

			const structure = await createInventoryStructure({
				categoryName: `E2E Smoke Interlock ${tag}`,
				definitions: [
					{
						label: "Maker",
						valueType: "text",
						required: true,
						identifyingPosition: 0,
					},
				],
				containerPath: [`E2E Smoke Cage ${tag}`, `E2E Smoke Rack ${tag}`],
				operatorActorId: operator.memberId,
			});
			cleanups.push(() => structure.cleanUp());
			const makerDef = structure.definitionIds[0];
			const leaf = structure.containerIds[structure.containerIds.length - 1];
			const item = await createInventoryItem({
				categoryId: structure.categoryId,
				containerId: leaf,
				values: { [makerDef]: maker },
				actorId: operator.memberId,
			});
			cleanups.push(() => item.cleanUp());
			// SAFETY: every non-pair preset returns the flat loan row matching
			// the declared inventoryLoan result type (mirrors the wrapper).
			const loan = (await createInventoryLoan({
				preset: "approved",
				itemId: item.itemId,
				borrowerMemberId: borrower.memberId,
				operatorActorId: operator.memberId,
			})) as SeededLoan;
			cleanups.push(() => loan.cleanUp());

			await loginAsUser(context, operator.email);
			const blockedArchive = await apiStatus(
				page,
				`/inventory/items/${item.itemId}/archive`,
				{ reason: `E2E interlock probe ${tag}` },
			);
			expect(blockedArchive).toBe(409);

			const blockedMaintenance = await apiStatus(
				page,
				`/inventory/items/${item.itemId}/maintenance/start`,
				{ reason: `E2E interlock probe ${tag}` },
			);
			expect(blockedMaintenance).toBe(409);

			const checkedOut = await apiStatus(
				page,
				`/inventory/operator/loans/${loan.loanId}/checkout`,
			);
			expect(checkedOut).toBe(200);
			const returned = await apiStatus(
				page,
				`/inventory/operator/loans/${loan.loanId}/return`,
			);
			expect(returned).toBe(200);

			const archived = await apiStatus(
				page,
				`/inventory/items/${item.itemId}/archive`,
				{ reason: `E2E retired ${tag}` },
			);
			expect(archived).toBe(200);

			// Member-visible outcome: the catalog hides the item while the
			// borrower's own-loan history keeps it.
			await loginAsUser(context, borrower.email);
			await page.goto("/dashboard/equipment");
			await page.getByLabel("Search items").fill(maker);
			await page.getByLabel("Search items").press("Enter");
			await expect(
				page.getByText("Nothing matches those filters"),
			).toBeVisible();

			await page.goto("/dashboard/my-loans");
			await page.getByRole("link", { name: maker }).click();
			await expect(
				page.getByRole("dialog").getByRole("heading", { name: maker }),
			).toBeVisible();
		} finally {
			for (const cleanUp of cleanups.reverse()) {
				try {
					await cleanUp();
				} catch {
					/* best-effort: per-run database is disposable */
				}
			}
		}
	});

	test("overdue loans, unauthenticated and inactive-member responses", async ({
		page,
		context,
	}) => {
		const tag = `smoke-auth-${Date.now().toString(36)}`;
		const maker = `Smoke Overdue Feder ${tag}`;
		const cleanups: Array<() => Promise<void>> = [];
		try {
			const operator = await createMember({
				email: createUniqueEmail("inv-smoke-auth-op"),
				roles: new Set(["member", "quartermaster"]),
			});
			cleanups.push(() => operator.cleanUp());
			const borrower = await createMember({
				email: createUniqueEmail("inv-smoke-auth-member"),
			});
			cleanups.push(() => borrower.cleanUp());
			const inactive = await createMember({
				email: createUniqueEmail("inv-smoke-auth-inactive"),
				isActive: false,
			});
			cleanups.push(() => inactive.cleanUp());

			const structure = await createInventoryStructure({
				categoryName: `E2E Smoke Auth ${tag}`,
				definitions: [
					{
						label: "Maker",
						valueType: "text",
						required: true,
						identifyingPosition: 0,
					},
				],
				containerPath: [`E2E Smoke Cage ${tag}`, `E2E Smoke Rack ${tag}`],
				operatorActorId: operator.memberId,
			});
			cleanups.push(() => structure.cleanUp());
			const makerDef = structure.definitionIds[0];
			const leaf = structure.containerIds[structure.containerIds.length - 1];
			const item = await createInventoryItem({
				categoryId: structure.categoryId,
				containerId: leaf,
				values: { [makerDef]: maker },
				actorId: operator.memberId,
			});
			cleanups.push(() => item.cleanUp());
			// SAFETY: every non-pair preset returns the flat loan row matching
			// the declared inventoryLoan result type (mirrors the wrapper).
			const overdue = (await createInventoryLoan({
				preset: "overdue",
				itemId: item.itemId,
				borrowerMemberId: borrower.memberId,
				operatorActorId: operator.memberId,
			})) as SeededLoan;
			expect(overdue.overdue).toBe(true);
			cleanups.push(() => overdue.cleanUp());

			// Overdue geometry is member-visible as urgency in My Loans.
			await loginAsUser(context, borrower.email);
			await page.goto("/dashboard/my-loans");
			const card = page.getByRole("link", { name: maker });
			await expect(card).toBeVisible();
			await expect(card.getByText("Overdue", { exact: true })).toBeVisible();

			// Signed-out browsers are sent to /auth, never the catalog.
			await context.clearCookies();
			await page.goto("/dashboard/equipment");
			await expect(page).toHaveURL(/\/auth/);

			// Signed-out API calls are rejected, not served.
			const signedOut = await page.request.get(
				`${API_BASE_URL}/inventory/catalog/items`,
			);
			expect(signedOut.status()).toBe(401);

			// Inactive members hold a cookie but the session is refused.
			await loginAsUser(context, inactive.email);
			const inactiveApi = await page.request.get(
				`${API_BASE_URL}/inventory/catalog/items`,
			);
			expect([401, 403]).toContain(inactiveApi.status());
			await page.goto("/dashboard/equipment");
			await expect(
				page.getByRole("heading", { name: "Find the right kit" }),
			).toHaveCount(0);
		} finally {
			for (const cleanUp of cleanups.reverse()) {
				try {
					await cleanUp();
				} catch {
					/* best-effort: per-run database is disposable */
				}
			}
		}
	});

	test("schema version is present and reminder reconciliation is idempotent", async () => {
		const status = await fetchE2EStatus();
		expect(status.schemaVersion).toEqual(expect.any(Number));
		expect(status.schemaVersion).toBeGreaterThan(0);
		expect(status.today).toMatch(/^\d{4}-\d{2}-\d{2}$/);

		const tag = `smoke-remind-${Date.now().toString(36)}`;
		const maker = `Smoke Reminder Feder ${tag}`;
		const cleanups: Array<() => Promise<void>> = [];
		try {
			const operator = await createMember({
				email: createUniqueEmail("inv-smoke-remind-op"),
				roles: new Set(["member", "quartermaster"]),
			});
			cleanups.push(() => operator.cleanUp());
			const borrower = await createMember({
				email: createUniqueEmail("inv-smoke-remind-member"),
			});
			cleanups.push(() => borrower.cleanUp());

			const structure = await createInventoryStructure({
				categoryName: `E2E Smoke Remind ${tag}`,
				definitions: [
					{
						label: "Maker",
						valueType: "text",
						required: true,
						identifyingPosition: 0,
					},
				],
				containerPath: [`E2E Smoke Cage ${tag}`, `E2E Smoke Rack ${tag}`],
				operatorActorId: operator.memberId,
			});
			cleanups.push(() => structure.cleanUp());
			const makerDef = structure.definitionIds[0];
			const leaf = structure.containerIds[structure.containerIds.length - 1];
			const item = await createInventoryItem({
				categoryId: structure.categoryId,
				containerId: leaf,
				values: { [makerDef]: maker },
				actorId: operator.memberId,
			});
			cleanups.push(() => item.cleanUp());
			// SAFETY: every non-pair preset returns the flat loan row matching
			// the declared inventoryLoan result type (mirrors the wrapper).
			const loan = (await createInventoryLoan({
				preset: "approved",
				itemId: item.itemId,
				borrowerMemberId: borrower.memberId,
				operatorActorId: operator.memberId,
				reminderState: "preDue",
			})) as SeededLoan;
			expect(loan.owedKind).toBe("pre_due");
			expect(loan.notificationKey).toContain(
				`inventory:loan:${loan.loanId}:reminder:pre_due:`,
			);
			cleanups.push(() => loan.cleanUp());

			const first = await runLoanReminders({ loanId: loan.loanId });
			expect(first.reminderNotificationCount).toBe(1);

			const second = await runLoanReminders({ loanId: loan.loanId });
			expect(second.reminderNotificationCount).toBe(1);
		} finally {
			for (const cleanUp of cleanups.reverse()) {
				try {
					await cleanUp();
				} catch {
					/* best-effort: per-run database is disposable */
				}
			}
		}
	});
});
