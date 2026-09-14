import { test, expect } from "@playwright/test";
import { loginAsUser } from "./auth";
import { API_BASE_URL, seedE2EScenario } from "./e2eApi";
import {
	createInventoryItem,
	createInventoryLoan,
	createInventoryStructure,
	createMember,
	createOpenMaintenance,
	createUniqueEmail,
} from "./setupFunctions";

// ALE-288 M2: member-visible availability. Pins the generic projection rule:
// the member catalog carries only `available | on_loan | maintenance` with
// no reason text, no container path, no operator note — while pending
// requests deliberately keep the item requestable.
test.use({ viewport: { width: 375, height: 812 } });

const tag = `avail-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const categoryName = `E2E Avail Blades ${tag}`;
const rackName = `E2E Avail Rack ${tag}`;
const makerMaint = `Quarantined Feder ${tag}`;
const makerClosed = `Serviced Feder ${tag}`;
const makerPending = `Requested Feder ${tag}`;
const makerApproved = `Allocated Feder ${tag}`;
const makerCheckedOut = `Borrowed Feder ${tag}`;
const maintenanceReason = `E2E cracked guard quarantine ${tag}`;
const operatorNote = `E2E armoury note ${tag}`;

let viewerEmail = "";
let borrowerMemberId = "";
let slugMaint = "";
let slugPending = "";
let slugApproved = "";
let slugCheckedOut = "";
const cleanups: Array<() => Promise<void>> = [];

function isoDate(offsetDays: number): string {
	return new Date(Date.now() + offsetDays * 86_400_000)
		.toISOString()
		.slice(0, 10);
}

test.describe("ALE-288 inventory member availability", () => {
	test.beforeAll(async () => {
		const operator = await createMember({
			email: createUniqueEmail("inv-avail-op"),
			roles: new Set(["member", "quartermaster"]),
		});
		cleanups.push(() => operator.cleanUp());

		const viewer = await createMember({
			email: createUniqueEmail("inv-avail-viewer"),
		});
		cleanups.push(() => viewer.cleanUp());
		viewerEmail = viewer.email;

		const borrower = await createMember({
			email: createUniqueEmail("inv-avail-borrower"),
		});
		cleanups.push(() => borrower.cleanUp());
		borrowerMemberId = borrower.memberId;

		const structure = await createInventoryStructure({
			categoryName,
			definitions: [
				{
					label: "Maker",
					valueType: "text",
					required: true,
					identifyingPosition: 0,
				},
			],
			containerPath: [`E2E Avail Cage ${tag}`, rackName],
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => structure.cleanUp());
		const makerDef = structure.definitionIds[0];
		const leaf = structure.containerIds[structure.containerIds.length - 1];

		const seedItem = async (maker: string) => {
			const item = await createInventoryItem({
				categoryId: structure.categoryId,
				containerId: leaf,
				values: { [makerDef]: maker },
				notes: operatorNote,
				actorId: operator.memberId,
			});
			cleanups.push(() => item.cleanUp());
			return item;
		};

		const maint = await seedItem(makerMaint);
		slugMaint = maint.slug;
		const maintenance = await createOpenMaintenance({
			itemId: maint.itemId,
			reason: maintenanceReason,
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => maintenance.cleanUp());

		const closed = await seedItem(makerClosed);
		const closedPeriod = await seedE2EScenario("inventoryMaintenance", {
			preset: "closed",
			itemId: closed.itemId,
			reason: `E2E routine check ${tag}`,
			operatorActorId: operator.memberId,
		});
		expect(closedPeriod.open).toBe(false);

		const pending = await seedItem(makerPending);
		slugPending = pending.slug;
		const requested = await createInventoryLoan({
			preset: "requested",
			itemId: pending.itemId,
			borrowerMemberId,
		});
		cleanups.push(() => requested.cleanUp());

		const approved = await seedItem(makerApproved);
		slugApproved = approved.slug;
		const approvedLoan = await createInventoryLoan({
			preset: "approved",
			itemId: approved.itemId,
			borrowerMemberId,
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => approvedLoan.cleanUp());

		const checkedOut = await seedItem(makerCheckedOut);
		slugCheckedOut = checkedOut.slug;
		const checkedOutLoan = await createInventoryLoan({
			preset: "checkedOut",
			itemId: checkedOut.itemId,
			borrowerMemberId,
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => checkedOutLoan.cleanUp());
	});

	test.afterAll(async () => {
		// Best-effort in reverse creation order (loans/periods first, then
		// items, structure, members). The per-run database is disposable;
		// unique fixture text keeps leftovers out of other specs.
		for (const cleanUp of cleanups.reverse()) {
			try {
				await cleanUp();
			} catch {
				/* best-effort: per-run database is disposable */
			}
		}
	});

	test("open maintenance keeps the item visible as Maintenance with no request action", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");

		const card = page.getByRole("link", { name: makerMaint });
		await expect(card).toBeVisible();
		await expect(card.getByText("Maintenance")).toBeVisible();

		await page.goto(`/dashboard/equipment/${slugMaint}`);
		await expect(page.getByRole("heading", { name: makerMaint })).toBeVisible();
		await expect(page.getByText("Maintenance")).toBeVisible();
		await expect(page.getByText("isn't requestable right now")).toBeVisible();
		await expect(
			page.getByRole("button", { name: "Send request" }),
		).toHaveCount(0);
	});

	test("operator reason, note and container path never appear member-side", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");
		await expect(page.getByRole("link", { name: makerMaint })).toBeVisible();
		await expect(page.getByText(maintenanceReason)).toHaveCount(0);
		await expect(page.getByText(operatorNote)).toHaveCount(0);
		await expect(page.getByText(rackName)).toHaveCount(0);

		await page.goto(`/dashboard/equipment/${slugMaint}`);
		await expect(page.getByRole("heading", { name: makerMaint })).toBeVisible();
		await expect(page.getByText(maintenanceReason)).toHaveCount(0);
		await expect(page.getByText(operatorNote)).toHaveCount(0);
		await expect(page.getByText(rackName)).toHaveCount(0);
	});

	test("a pending request does not make the item unavailable", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");

		const card = page.getByRole("link", { name: makerPending });
		await expect(card).toBeVisible();
		await expect(card.getByText("Available")).toBeVisible();

		await page.goto(`/dashboard/equipment/${slugPending}`);
		await expect(
			page.getByRole("heading", { name: "Request this item" }),
		).toBeVisible();
		await expect(
			page.getByRole("button", { name: "Send request" }),
		).toBeVisible();
	});

	test("an approved or checked-out loan makes the item On loan and unavailable", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");

		for (const maker of [makerApproved, makerCheckedOut]) {
			const card = page.getByRole("link", { name: maker });
			await expect(card).toBeVisible();
			await expect(card.getByText("On loan")).toBeVisible();
		}

		await page.goto(`/dashboard/equipment/${slugApproved}`);
		await expect(
			page.getByRole("heading", { name: makerApproved }),
		).toBeVisible();
		await expect(page.getByText("On loan", { exact: true })).toBeVisible();
		await expect(
			page.getByRole("button", { name: "Send request" }),
		).toHaveCount(0);
		// Approval is the collection entitlement — members without an
		// approved loan on this item learn nothing about its location.
		await expect(page.getByText(rackName)).toHaveCount(0);

		await page.goto(`/dashboard/equipment/${slugCheckedOut}`);
		await expect(
			page.getByRole("heading", { name: makerCheckedOut }),
		).toBeVisible();
		await expect(
			page.getByRole("button", { name: "Send request" }),
		).toHaveCount(0);
	});

	test("requesting an item under maintenance is refused without a 500", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);

		const response = await page.request.post(
			`${API_BASE_URL}/inventory/catalog/items/${slugMaint}/requests`,
			{ data: { startsOn: isoDate(0), dueOn: isoDate(7) } },
		);
		expect(response.status()).toBe(409);
		// SAFETY: Phoenix renders loan conflicts as `{ errors: { detail, code } }`
		// (see InventoryMemberLoanConflictError); only `code`/`detail` are read.
		const body = (await response.json()) as {
			errors: { detail: string; code: string };
		};
		expect(body.errors.code).toBe("item_unavailable");
		expect(body.errors.detail).toBe("The item cannot be requested right now");
		// The generic refusal leaks neither the reason nor the location.
		expect(body.errors.detail).not.toContain(maintenanceReason);
		expect(body.errors.detail).not.toContain(rackName);
	});
});
