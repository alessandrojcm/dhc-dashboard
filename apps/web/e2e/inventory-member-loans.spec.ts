import { test, expect } from "@playwright/test";
import { loginAsUser } from "./auth";
import { seedE2EScenario, type InventoryLoanSeed } from "./e2eApi";
import {
	createInventoryItem,
	createInventoryLoan,
	createInventoryStructure,
	createMember,
	createUniqueEmail,
} from "./setupFunctions";

// ALE-288 M4: own-loan history at explicit mobile width. Every row renders
// the retained snapshot (never a live item read), cancel stays available
// only before checkout, the container path is an approval entitlement, and
// another member's loan URL answers not-found.
test.use({ viewport: { width: 375, height: 812 } });

const tag = `loans-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const makerRequested = `Requested Feder ${tag}`;
const makerRequestedCancel = `Requested Cancel Feder ${tag}`;
const makerApproved = `Approved Feder ${tag}`;
const makerApprovedCancel = `Approved Cancel Feder ${tag}`;
const makerCheckedOut = `Checked Out Feder ${tag}`;
const makerReturned = `Returned Feder ${tag}`;
const makerRejected = `Rejected Feder ${tag}`;
const makerCancelled = `Cancelled Feder ${tag}`;
const makerArchived = `Archived Feder ${tag}`;

type SeededLoan = InventoryLoanSeed["result"] & { cleanUp(): Promise<void> };

let borrowerEmail = "";
let otherEmail = "";
const loans: Record<string, SeededLoan> = {};
const cleanups: Array<() => Promise<void>> = [];

test.describe("ALE-288 inventory member loans", () => {
	test.beforeAll(async () => {
		const operator = await createMember({
			email: createUniqueEmail("inv-loans-op"),
			roles: new Set(["member", "quartermaster"]),
		});
		cleanups.push(() => operator.cleanUp());

		const borrower = await createMember({
			email: createUniqueEmail("inv-loans-borrower"),
		});
		cleanups.push(() => borrower.cleanUp());
		borrowerEmail = borrower.email;

		const other = await createMember({
			email: createUniqueEmail("inv-loans-other"),
		});
		cleanups.push(() => other.cleanUp());
		otherEmail = other.email;

		const structure = await createInventoryStructure({
			categoryName: `E2E Loans Blades ${tag}`,
			definitions: [
				{
					label: "Maker",
					valueType: "text",
					required: true,
					identifyingPosition: 0,
				},
			],
			containerPath: [`E2E Loans Cage ${tag}`, `E2E Loans Rack ${tag}`],
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => structure.cleanUp());
		const makerDef = structure.definitionIds[0];
		const leaf = structure.containerIds[structure.containerIds.length - 1];

		const seedLoan = async (
			key: string,
			maker: string,
			attrs: Omit<
				Parameters<typeof createInventoryLoan>[0],
				"itemId" | "borrowerMemberId" | "operatorActorId"
			> & { cancelledBy?: "member" | "operator" },
		) => {
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
				...attrs,
				itemId: item.itemId,
				borrowerMemberId: borrower.memberId,
				operatorActorId: operator.memberId,
			})) as SeededLoan;
			cleanups.push(() => loan.cleanUp());
			loans[key] = loan;
			return { item, loan };
		};

		await seedLoan("requested", makerRequested, { preset: "requested" });
		await seedLoan("requestedCancel", makerRequestedCancel, {
			preset: "requested",
		});
		await seedLoan("approved", makerApproved, { preset: "approved" });
		await seedLoan("approvedCancel", makerApprovedCancel, {
			preset: "approved",
		});
		await seedLoan("checkedOut", makerCheckedOut, { preset: "checkedOut" });
		await seedLoan("returned", makerReturned, { preset: "returned" });
		await seedLoan("rejected", makerRejected, { preset: "rejected" });
		await seedLoan("cancelled", makerCancelled, { preset: "cancelled" });

		// Archived item with retained history: a returned loan, then archive.
		const { item: archivedItem } = await seedLoan("archived", makerArchived, {
			preset: "returned",
		});
		const archived = await seedE2EScenario("inventoryArchive", {
			itemId: archivedItem.itemId,
			reason: `Retired beyond repair ${tag}`,
			operatorActorId: operator.memberId,
		});
		expect(archived.catalogHidden).toBe(true);
		expect(archived.historyKept).toBe(true);
	});

	test.afterAll(async () => {
		// Best-effort in reverse creation order (loans first, then items,
		// structure, members). Items with loan history archive instead of
		// deleting; the per-run database is disposable and fixture text is
		// unique per run.
		for (const cleanUp of cleanups.reverse()) {
			try {
				await cleanUp();
			} catch {
				/* best-effort: per-run database is disposable */
			}
		}
	});

	test("My Loans supports all, open and closed views with full history", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);
		await page.goto("/dashboard/my-loans");

		for (const maker of [
			makerRequested,
			makerApproved,
			makerCheckedOut,
			makerReturned,
			makerRejected,
			makerCancelled,
		]) {
			await expect(page.getByRole("link", { name: maker })).toBeVisible();
		}

		await page.getByRole("tab", { name: "Current" }).click();
		for (const maker of [makerRequested, makerApproved, makerCheckedOut]) {
			await expect(page.getByRole("link", { name: maker })).toBeVisible();
		}
		await expect(page.getByRole("link", { name: makerReturned })).toHaveCount(
			0,
		);
		await expect(page.getByRole("link", { name: makerRejected })).toHaveCount(
			0,
		);
		await expect(page.getByRole("link", { name: makerCancelled })).toHaveCount(
			0,
		);

		await page.getByRole("tab", { name: "Past" }).click();
		for (const maker of [makerReturned, makerRejected, makerCancelled]) {
			await expect(page.getByRole("link", { name: maker })).toBeVisible();
		}
		await expect(page.getByRole("link", { name: makerRequested })).toHaveCount(
			0,
		);
		await expect(page.getByRole("link", { name: makerCheckedOut })).toHaveCount(
			0,
		);
	});

	test("requested and approved loans can be cancelled from own-loan detail", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);

		await page.goto(`/dashboard/my-loans/${loans.requestedCancel.loanId}`);
		await expect(
			page.getByRole("heading", { name: "Cancel this loan" }),
		).toBeVisible();
		await page.getByRole("button", { name: "Cancel loan" }).click();
		await expect(page.getByText("Loan cancelled")).toBeVisible();
		await expect(page.getByText("cancelled").first()).toBeVisible();

		await page.goto(`/dashboard/my-loans/${loans.approvedCancel.loanId}`);
		await expect(
			page.getByRole("heading", { name: "Cancel this loan" }),
		).toBeVisible();
		await page.getByRole("button", { name: "Cancel loan" }).click();
		await expect(page.getByText("Loan cancelled")).toBeVisible();
		await expect(page.getByText("cancelled").first()).toBeVisible();
	});

	test("checked-out loans cannot be cancelled from own-loan detail", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);
		await page.goto(`/dashboard/my-loans/${loans.checkedOut.loanId}`);

		await expect(
			page.getByText("hand it back to a quartermaster"),
		).toBeVisible();
		await expect(page.getByRole("button", { name: "Cancel loan" })).toHaveCount(
			0,
		);
		await expect(
			page.getByRole("heading", { name: "Cancel this loan" }),
		).toHaveCount(0);
	});

	test("container path is absent before approval and present after", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);

		await page.goto(`/dashboard/my-loans/${loans.requested.loanId}`);
		await expect(
			page.getByRole("heading", { name: makerRequested }),
		).toBeVisible();
		await expect(page.getByText(/Collect from/)).toHaveCount(0);

		await page.goto(`/dashboard/my-loans/${loans.approved.loanId}`);
		await expect(
			page.getByRole("heading", { name: makerApproved }),
		).toBeVisible();
		await expect(page.getByText(/Collect from/)).toBeVisible();
	});

	test("archived item stays in own-loan history while leaving the catalog", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, borrowerEmail);

		// Own-loan history keeps the snapshot.
		await page.goto("/dashboard/my-loans");
		await expect(page.getByRole("link", { name: makerArchived })).toBeVisible();
		await page.getByRole("link", { name: makerArchived }).click();
		await expect(
			page.getByRole("heading", { name: makerArchived }),
		).toBeVisible();

		// The catalog hides it: search finds nothing and direct detail 404s.
		await page.goto("/dashboard/equipment");
		await page.getByLabel("Search items").fill(makerArchived);
		await page.getByLabel("Search items").press("Enter");
		await expect(page.getByText("Nothing matches those filters")).toBeVisible();

		await page.goto(`/dashboard/equipment/${loans.archived.slug}`);
		// The query client retries failed reads with backoff, so the
		// settled error lands after the default assertion window.
		await expect(page.getByText("Item not found")).toBeVisible({
			timeout: 15_000,
		});
	});

	test("another member cannot read this member's loan by guessing its URL", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, otherEmail);
		await page.goto(`/dashboard/my-loans/${loans.requested.loanId}`);

		// The query client retries failed reads with backoff, so the
		// settled error lands after the default assertion window.
		await expect(page.getByText("Loan not found")).toBeVisible({
			timeout: 15_000,
		});
		// No borrower or operator facts leak on the forbidden page.
		await expect(page.getByText(/Collect from/)).toHaveCount(0);
		await expect(page.getByText(makerRequested)).toHaveCount(0);
	});
});
