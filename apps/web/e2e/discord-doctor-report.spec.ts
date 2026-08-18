import { expect, test, type Page } from "@playwright/test";
import { loginAsUser } from "./auth";
import { createMember } from "./setupFunctions";

const report = {
	data: {
		serverMembers: {
			linkedActive: [
				{
					discordUserId: "discord-active",
					username: "aoife.byrne",
					displayName: "Aoife",
					avatar: null,
					joinedAt: "2024-02-10T10:00:00Z",
					member: {
						id: "00000000-0000-4000-8000-000000000001",
						firstName: "Aoife",
						lastName: "Byrne",
					},
					membershipStatus: "active",
					protected: true,
					kickable: false,
				},
			],
			linkedInactive: [
				{
					discordUserId: "discord-inactive",
					username: "sean.brennan",
					displayName: "Seán",
					avatar: null,
					joinedAt: "2023-03-30T10:00:00Z",
					member: {
						id: "00000000-0000-4000-8000-000000000002",
						firstName: "Seán",
						lastName: "Brennan",
					},
					membershipStatus: "inactive",
					protected: false,
					kickable: true,
				},
			],
			pendingLink: [
				{
					discordUserId: "discord-pending",
					username: "fionnuala.k",
					displayName: "Fionnuala",
					avatar: null,
					joinedAt: "2025-04-19T10:00:00Z",
					member: {
						id: "00000000-0000-4000-8000-000000000003",
						firstName: "Fionnuala",
						lastName: "Kelly",
					},
					membershipStatus: "paused",
					protected: false,
					kickable: true,
				},
			],
			unrecognized: [
				{
					discordUserId: "discord-unknown",
					username: "unknown.account",
					displayName: "Unknown",
					avatar: null,
					joinedAt: "2025-08-20T10:00:00Z",
					member: null,
					membershipStatus: null,
					protected: false,
					kickable: true,
				},
			],
		},
		missingMembers: [
			{
				member: {
					id: "00000000-0000-4000-8000-000000000004",
					firstName: "Maeve",
					lastName: "Doyle",
				},
				membershipStatus: "active",
				linkStatus: "linked",
				discordUserId: "discord-missing",
				autoJoinPending: false,
			},
			{
				member: {
					id: "00000000-0000-4000-8000-000000000005",
					firstName: "Niamh",
					lastName: "Murphy",
				},
				membershipStatus: "active",
				linkStatus: "never_linked",
				discordUserId: null,
				autoJoinPending: true,
			},
		],
		cache: {
			fetchedAt: new Date().toISOString(),
			ttlSeconds: 60,
		},
	},
};

async function stubDoctorReport(page: Page, requests: URL[] = []) {
	await page.route("**/api/discord-doctor/report**", async (route) => {
		requests.push(new URL(route.request().url()));
		const response = {
			...report,
			data: {
				...report.data,
				cache: {
					...report.data.cache,
					fetchedAt: new Date().toISOString(),
				},
			},
		};
		await route.fulfill({
			contentType: "application/json",
			headers: {
				"access-control-allow-credentials": "true",
				"access-control-allow-origin": "http://127.0.0.1:5173",
			},
			body: JSON.stringify(response),
		});
	});
}

test.describe("Discord Doctor report", () => {
	let admin: Awaited<ReturnType<typeof createMember>>;
	let president: Awaited<ReturnType<typeof createMember>>;
	let committeeCoordinator: Awaited<ReturnType<typeof createMember>>;
	let member: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();
		[admin, president, committeeCoordinator, member] = await Promise.all([
			createMember({
				email: `discord-doctor-admin-${timestamp}@test.com`,
				roles: new Set(["admin"]),
			}),
			createMember({
				email: `discord-doctor-president-${timestamp}@test.com`,
				roles: new Set(["president"]),
			}),
			createMember({
				email: `discord-doctor-coordinator-${timestamp}@test.com`,
				roles: new Set(["committee_coordinator"]),
			}),
			createMember({
				email: `discord-doctor-member-${timestamp}@test.com`,
				roles: new Set(["member"]),
			}),
		]);
	});

	test.afterAll(async () => {
		await Promise.all([
			admin.cleanUp(),
			president.cleanUp(),
			committeeCoordinator.cleanUp(),
			member.cleanUp(),
		]);
	});

	test("shows navigation and route access only to Discord Doctor roles", async ({
		page,
		context,
	}) => {
		await stubDoctorReport(page);

		for (const authorizedMember of [admin, president, committeeCoordinator]) {
			await loginAsUser(context, authorizedMember.email);
			await page.goto("/dashboard");
			await expect(
				page.getByRole("link", { name: "Discord Doctor", exact: true }),
			).toBeVisible();

			await page.goto("/dashboard/discord-doctor");
			await expect(
				page.getByRole("heading", { name: "Discord Doctor", exact: true }),
			).toBeVisible();
		}

		await loginAsUser(context, member.email);
		await page.goto("/dashboard");
		await expect(
			page.getByRole("link", { name: "Discord Doctor", exact: true }),
		).toHaveCount(0);

		await page.goto("/dashboard/discord-doctor");
		await expect(page).toHaveURL(`/dashboard/members/${member.userId}`);
	});

	test("renders every server bucket and the single missing-members view", async ({
		page,
		context,
	}) => {
		const requests: URL[] = [];
		await stubDoctorReport(page, requests);
		await loginAsUser(context, admin.email);
		await page.goto("/dashboard/discord-doctor");
		await expect.poll(() => requests.length).toBeGreaterThan(0);

		for (const tabName of [
			"Linked – active 1",
			"Linked – inactive 1",
			"Pending link 1",
			"Unrecognized 1",
		]) {
			await expect(page.getByRole("tab", { name: tabName })).toBeVisible();
		}

		await expect(page.getByText("Aoife", { exact: true })).toBeVisible();
		await expect(page.getByText("Protected", { exact: true })).toBeVisible();

		await page.getByRole("tab", { name: "Pending link 1" }).click();
		await expect(page.getByText("Fionnuala", { exact: true })).toBeVisible();
		await expect(
			page.getByText(/Unconfirmed match — verify on Discord first/i),
		).toBeVisible();

		await page.getByRole("button", { name: "Members view" }).click();
		await expect(
			page.getByRole("heading", { name: "Missing from server (2)" }),
		).toBeVisible();
		await expect(page.getByText("Maeve Doyle", { exact: true })).toBeVisible();
		await expect(page.getByText("Never linked", { exact: true })).toBeVisible();
		await expect(
			page.getByText("Auto-join pending", { exact: true }),
		).toBeVisible();

		await expect(page.getByRole("button", { name: /kick/i })).toHaveCount(0);
		await expect(page.locator("body")).not.toContainText(
			/\bguild\b|\broster\b/i,
		);
	});

	test("refreshes the member list with a cache bypass", async ({
		page,
		context,
	}) => {
		const requests: URL[] = [];
		await stubDoctorReport(page, requests);
		await loginAsUser(context, admin.email);
		await page.goto("/dashboard/discord-doctor");
		await expect.poll(() => requests.length).toBeGreaterThan(0);

		await expect(page.getByRole("status")).toContainText(
			/Members fetched \d+s ago/,
		);
		await page.getByRole("button", { name: "Refresh members" }).click();

		await expect
			.poll(() =>
				requests.some((url) => url.searchParams.get("refresh") === "true"),
			)
			.toBe(true);
		await expect(page.getByRole("status")).toContainText(
			/Members fetched \d+s ago/,
		);
	});
});
