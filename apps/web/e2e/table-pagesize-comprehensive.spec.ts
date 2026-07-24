import { expect, type Page, test } from "@playwright/test";
import { loginAsUser } from "./auth";
import { createMember, createUniqueEmail } from "./setupFunctions";

type TableCase = {
	name: string;
	path: string;
	tab: string;
	pageSizeLabel: string;
};

const tableCases: TableCase[] = [
	{
		name: "members",
		path: "/dashboard/members?tab=members",
		tab: "Members list",
		pageSizeLabel: "Members elements per page",
	},
	{
		name: "waitlist",
		path: "/dashboard/beginners-workshop?tab=waitlist",
		tab: "Waitlist",
		pageSizeLabel: "Waitlist elements per page",
	},
];

async function expectQueryParam(page: Page, key: string, value: string) {
	await expect
		.poll(() => new URL(page.url()).searchParams.get(key) ?? "")
		.toBe(value);
}

test.describe("Table page size", () => {
	let admin: Awaited<ReturnType<typeof createMember>>;
	const members: Awaited<ReturnType<typeof createMember>>[] = [];

	test.beforeAll(async () => {
		test.setTimeout(120_000);
		admin = await createMember({
			email: createUniqueEmail("page-size-admin"),
			roles: new Set(["admin"]),
			createSubscription: false,
		});

		const seededMembers = await Promise.all(
			Array.from({ length: 26 }, (_, index) =>
				createMember({
					email: createUniqueEmail("page-size-member", index),
					roles: new Set(["member"]),
					createSubscription: false,
				}),
			),
		);
		members.push(...seededMembers);
	});

	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, admin.email);
	});

	test.afterAll(async () => {
		await Promise.all([
			admin?.cleanUp().catch(console.error),
			...members.map((member) => member.cleanUp().catch(console.error)),
		]);
	});

	for (const tableCase of tableCases) {
		test(`${tableCase.name} page size updates`, async ({ page }) => {
			await page.goto(
				tableCase.name === "members"
					? `${tableCase.path}&pageSize=25`
					: tableCase.path,
			);
			await expect(
				page.getByRole("tab", { name: tableCase.tab }),
			).toHaveAttribute("data-state", "active");

			const pageSize = page.getByRole("button", {
				name: tableCase.pageSizeLabel,
			});
			if (tableCase.name === "waitlist") {
				await pageSize.click();
				await page.getByRole("option", { name: "25" }).click();
			}
			await expectQueryParam(page, "pageSize", "25");
			await expect(pageSize).toContainText("25");

			if (tableCase.name === "members") {
				const next = page.getByRole("button", { name: "Next" });
				await expect(next).toBeEnabled();
				await next.click();
				await expectQueryParam(page, "pageSize", "25");
				await expect
					.poll(() => new URL(page.url()).searchParams.get("cursor") ?? "")
					.not.toBe("");
				await expect(pageSize).toContainText("25");
			}
		});
	}
});
