import { test, expect, type Page } from "@playwright/test";
import { loginAsUser } from "./auth";
import { seedE2EScenario } from "./e2eApi";
import {
	createInventoryItem,
	createInventoryStructure,
	createMember,
	createOpenMaintenance,
	createUniqueEmail,
} from "./setupFunctions";

// ALE-288 M1: member catalog browse at explicit mobile width. The global
// Playwright config uses a host-dependent viewport, so every inventory spec
// pins the mobile journey viewport itself.
test.use({ viewport: { width: 375, height: 812 } });

const tag = `browse-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const categoryA = `E2E Browse Blades ${tag}`;
const categoryB = `E2E Browse Masks ${tag}`;
const makerA1 = `Regenyei Feder ${tag}`;
const makerA2 = `Blackfencer Feder ${tag}`;
const makerB1 = `Red Dragon Mask ${tag}`;
const makerM1 = `Cracked Guard ${tag}`;
const makerX1 = `Retired Blade ${tag}`;
const maintenanceReason = `E2E cracked guard quarantine ${tag}`;

let viewerEmail = "";
let slugA1 = "";
const cleanups: Array<() => Promise<void>> = [];

async function selectFilterOption(
	page: Page,
	triggerText: string,
	optionName: string,
) {
	await page.getByRole("button", { name: triggerText }).click();
	await page.getByRole("option", { name: optionName, exact: true }).click();
}

test.describe("ALE-288 inventory member browse", () => {
	test.beforeAll(async () => {
		const operator = await createMember({
			email: createUniqueEmail("inv-browse-op"),
			roles: new Set(["member", "quartermaster"]),
		});
		cleanups.push(() => operator.cleanUp());

		const viewer = await createMember({
			email: createUniqueEmail("inv-browse-viewer"),
		});
		cleanups.push(() => viewer.cleanUp());
		viewerEmail = viewer.email;

		const structureA = await createInventoryStructure({
			categoryName: categoryA,
			definitions: [
				{
					label: "Maker",
					valueType: "text",
					required: true,
					identifyingPosition: 0,
				},
			],
			containerPath: [`E2E Browse Cage A ${tag}`, `Rack A ${tag}`],
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => structureA.cleanUp());
		const makerDefA = structureA.definitionIds[0];
		const leafA = structureA.containerIds[structureA.containerIds.length - 1];

		const structureB = await createInventoryStructure({
			categoryName: categoryB,
			definitions: [
				{
					label: "Maker",
					valueType: "text",
					required: true,
					identifyingPosition: 0,
				},
			],
			containerPath: [`E2E Browse Cage B ${tag}`, `Rack B ${tag}`],
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => structureB.cleanUp());
		const makerDefB = structureB.definitionIds[0];
		const leafB = structureB.containerIds[structureB.containerIds.length - 1];

		const itemA1 = await createInventoryItem({
			categoryId: structureA.categoryId,
			containerId: leafA,
			values: { [makerDefA]: makerA1 },
			actorId: operator.memberId,
		});
		cleanups.push(() => itemA1.cleanUp());
		slugA1 = itemA1.slug;

		const itemA2 = await createInventoryItem({
			categoryId: structureA.categoryId,
			containerId: leafA,
			values: { [makerDefA]: makerA2 },
			actorId: operator.memberId,
		});
		cleanups.push(() => itemA2.cleanUp());

		const itemB1 = await createInventoryItem({
			categoryId: structureB.categoryId,
			containerId: leafB,
			values: { [makerDefB]: makerB1 },
			actorId: operator.memberId,
		});
		cleanups.push(() => itemB1.cleanUp());

		const itemM1 = await createInventoryItem({
			categoryId: structureA.categoryId,
			containerId: leafA,
			values: { [makerDefA]: makerM1 },
			actorId: operator.memberId,
		});
		cleanups.push(() => itemM1.cleanUp());
		const maintenance = await createOpenMaintenance({
			itemId: itemM1.itemId,
			reason: maintenanceReason,
			operatorActorId: operator.memberId,
		});
		cleanups.push(() => maintenance.cleanUp());

		const itemX1 = await createInventoryItem({
			categoryId: structureA.categoryId,
			containerId: leafA,
			values: { [makerDefA]: makerX1 },
			actorId: operator.memberId,
		});
		cleanups.push(() => itemX1.cleanUp());
		const archived = await seedE2EScenario("inventoryArchive", {
			itemId: itemX1.itemId,
			reason: `Retired beyond repair ${tag}`,
			operatorActorId: operator.memberId,
		});
		expect(archived.catalogHidden).toBe(true);
	});

	test.afterAll(async () => {
		// Best-effort in reverse creation order: the disposable per-run
		// database does not need perfect teardown, and items carrying
		// maintenance/archive history archive instead of deleting (which
		// keeps their structure referenced). Fixture text stays unique per
		// run so leftovers cannot pollute other specs' assertions.
		for (const cleanUp of cleanups.reverse()) {
			try {
				await cleanUp();
			} catch {
				/* best-effort: per-run database is disposable */
			}
		}
	});

	test("member reaches Equipment from member navigation at mobile width", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard");
		// The dashboard home renders the member navigation as workspace
		// cards (navData-driven); the card is inside <main>, which scopes
		// past the hidden desktop sidebar link at this width.
		await page
			.getByRole("main")
			.getByRole("link", { name: "Equipment" })
			.click();
		await expect(page).toHaveURL(/\/dashboard\/equipment$/);
		await expect(
			page.getByRole("heading", { name: "Find the right kit" }),
		).toBeVisible();
	});

	test("catalog renders server-derived label, slug, category and availability badge", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");

		const card = page.getByRole("link", { name: makerA1 });
		await expect(card).toBeVisible();
		await expect(card.getByText(categoryA, { exact: true })).toBeVisible();
		await expect(card.getByText(`ID ${slugA1}`)).toBeVisible();
		await expect(card.getByText("Available")).toBeVisible();
		// Archived items never appear, even unfiltered.
		await expect(page.getByRole("link", { name: makerX1 })).toHaveCount(0);
	});

	test("search filters by relevant item text", async ({ page, context }) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");
		await expect(page.getByRole("link", { name: makerA1 })).toBeVisible();

		await page.getByLabel("Search items").fill(makerA1);
		await page.getByLabel("Search items").press("Enter");

		await expect(page.getByRole("link", { name: makerA1 })).toBeVisible();
		await expect(page.getByRole("link", { name: makerA2 })).toHaveCount(0);
		await expect(page.getByRole("link", { name: makerB1 })).toHaveCount(0);
	});

	test("category filter narrows results", async ({ page, context }) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");
		await expect(page.getByRole("link", { name: makerB1 })).toBeVisible();

		await selectFilterOption(page, "All categories", categoryA);

		await expect(page.getByRole("link", { name: makerA1 })).toBeVisible();
		await expect(page.getByRole("link", { name: makerA2 })).toBeVisible();
		await expect(page.getByRole("link", { name: makerB1 })).toHaveCount(0);
	});

	test("availability filters Everything, Available now and Unavailable", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");

		// Everything (default) shows the maintenance item beside available kit.
		await expect(page.getByRole("link", { name: makerM1 })).toBeVisible();
		await expect(
			page.getByRole("link", { name: makerM1 }).getByText("Maintenance"),
		).toBeVisible();

		await selectFilterOption(page, "Everything", "Available now");
		await expect(page.getByRole("link", { name: makerA1 })).toBeVisible();
		await expect(page.getByRole("link", { name: makerM1 })).toHaveCount(0);

		await selectFilterOption(page, "Available now", "Unavailable");
		await expect(page.getByRole("link", { name: makerM1 })).toBeVisible();
		await expect(page.getByRole("link", { name: makerA1 })).toHaveCount(0);
	});

	test("empty filtered result and Clear filters work", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");

		await page.getByLabel("Search items").fill(`zzz-no-such-item-${tag}`);
		await page.getByLabel("Search items").press("Enter");
		await expect(page.getByText("Nothing matches those filters")).toBeVisible();

		await page.getByRole("button", { name: "Clear filters" }).first().click();
		await expect(page.getByRole("link", { name: makerA1 })).toBeVisible();
	});

	test("archived items never appear, even when searched directly", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, viewerEmail);
		await page.goto("/dashboard/equipment");

		await page.getByLabel("Search items").fill(makerX1);
		await page.getByLabel("Search items").press("Enter");
		await expect(page.getByText("Nothing matches those filters")).toBeVisible();
		await expect(page.getByRole("link", { name: makerX1 })).toHaveCount(0);
	});
});
