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
				{
					discordUserId: "discord-protected-inactive",
					username: "ciaran.protected",
					displayName: "Ciarán",
					avatar: null,
					joinedAt: "2023-06-12T10:00:00Z",
					member: {
						id: "00000000-0000-4000-8000-000000000006",
						firstName: "Ciarán",
						lastName: "Protected",
					},
					membershipStatus: "inactive",
					protected: true,
					kickable: false,
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
				{
					discordUserId: "discord-left",
					username: "already.left",
					displayName: "Already Left",
					avatar: null,
					joinedAt: "2025-08-21T10:00:00Z",
					member: null,
					membershipStatus: null,
					protected: false,
					kickable: true,
				},
				{
					discordUserId: "discord-refused",
					username: "refused.account",
					displayName: "Refused Account",
					avatar: null,
					joinedAt: "2025-08-22T10:00:00Z",
					member: null,
					membershipStatus: null,
					protected: false,
					kickable: true,
				},
				{
					discordUserId: "discord-failed",
					username: "failed.account",
					displayName: "Failed Account",
					avatar: null,
					joinedAt: "2025-08-23T10:00:00Z",
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

type KickRequest = {
	discordUserIds: string[];
	note?: string;
};

type KickResult = {
	discordUserId: string;
	outcome: "kicked" | "already_left" | "refused" | "failed";
	reason: string | null;
	error: string | null;
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

async function stubDoctorKick(
	page: Page,
	results: KickResult[],
	requests: KickRequest[] = [],
) {
	await page.route("**/api/discord-doctor/kick", async (route) => {
		// SAFETY: this test controls the typed request producer and records its JSON body for an exact contract assertion below.
		requests.push(route.request().postDataJSON() as KickRequest);
		await route.fulfill({
			contentType: "application/json",
			headers: {
				"access-control-allow-credentials": "true",
				"access-control-allow-origin": "http://127.0.0.1:5173",
			},
			body: JSON.stringify({ data: { results } }),
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
			"Linked – inactive 2",
			"Pending link 1",
			"Unrecognized 4",
		]) {
			await expect(page.getByRole("tab", { name: tabName })).toBeVisible();
		}

		await expect(page.getByText("Aoife", { exact: true })).toBeVisible();
		await expect(
			page
				.getByLabel("Linked – active")
				.getByText("Protected", { exact: true }),
		).toBeVisible();

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

	test("offers only safe single and bulk kick controls", async ({
		page,
		context,
	}) => {
		await stubDoctorReport(page);
		await loginAsUser(context, admin.email);
		await page.goto("/dashboard/discord-doctor");

		await expect(page.getByRole("button", { name: /kick aoife/i })).toHaveCount(
			0,
		);
		await page.getByRole("tab", { name: "Linked – inactive 2" }).click();
		await expect(
			page.getByRole("button", { name: "Kick Seán", exact: true }),
		).toBeVisible();
		await expect(
			page.getByRole("button", { name: "Kick Ciarán", exact: true }),
		).toHaveCount(0);
		await expect(
			page.getByRole("button", { name: "Kick all inactive", exact: true }),
		).toBeVisible();

		await page.getByRole("tab", { name: "Pending link 1" }).click();
		await expect(
			page.getByRole("button", { name: "Kick Fionnuala", exact: true }),
		).toBeVisible();
		await expect(
			page.getByRole("button", { name: /kick all pending/i }),
		).toHaveCount(0);
		await page
			.getByRole("button", { name: "Kick Fionnuala", exact: true })
			.click();
		await expect(page.getByRole("alertdialog")).toContainText(
			"Unconfirmed match — verify on Discord first",
		);
		await page.getByRole("button", { name: "Cancel", exact: true }).click();

		await page.getByRole("tab", { name: "Unrecognized 4" }).click();
		await expect(
			page.getByRole("button", { name: "Kick all unrecognized", exact: true }),
		).toBeVisible();
	});

	test("reviews skipped inactive accounts and submits the exact explicit target list", async ({
		page,
		context,
	}) => {
		const reportRequests: URL[] = [];
		const kickRequests: KickRequest[] = [];
		await stubDoctorReport(page, reportRequests);
		await stubDoctorKick(
			page,
			[
				{
					discordUserId: "discord-inactive",
					outcome: "kicked",
					reason: null,
					error: null,
				},
			],
			kickRequests,
		);
		await loginAsUser(context, admin.email);
		await page.goto("/dashboard/discord-doctor");
		const initialReportRequests = reportRequests.length;
		await page.getByRole("tab", { name: "Linked – inactive 2" }).click();
		await page
			.getByRole("button", { name: "Kick all inactive", exact: true })
			.click();

		const dialog = page.getByRole("alertdialog");
		await expect(dialog).toContainText(
			"Kicks run immediately and are logged to the Discord audit log only — there is no record in this system",
		);
		await expect(
			dialog.getByText("Will be kicked (1)", { exact: true }),
		).toBeVisible();
		await expect(dialog.getByText("Seán", { exact: true })).toBeVisible();
		await expect(
			dialog.getByText("Skipped — will not be kicked (1)", { exact: true }),
		).toBeVisible();
		await expect(dialog.getByText("Ciarán", { exact: true })).toBeVisible();
		await expect(dialog).toContainText(
			`DHC Doctor — ${admin.first_name} ${admin.last_name}: linked_inactive`,
		);

		await dialog
			.getByLabel("Audit note (optional)")
			.fill("Reviewed with the committee");
		await expect(dialog).toContainText(
			`DHC Doctor — ${admin.first_name} ${admin.last_name}: linked_inactive — Reviewed with the committee`,
		);
		await dialog
			.getByRole("button", { name: "Kick 1 account", exact: true })
			.click();

		await expect
			.poll(() => kickRequests)
			.toEqual([
				{
					discordUserIds: ["discord-inactive"],
					note: "Reviewed with the committee",
				},
			]);
		await expect(
			page.getByText("Kick request completed", { exact: true }),
		).toBeVisible();
		await expect(
			page
				.getByRole("region", { name: "Latest kick results", exact: true })
				.getByText("Kicked", { exact: true }),
		).toBeVisible();
		await expect
			.poll(() => reportRequests.length)
			.toBeGreaterThan(initialReportRequests);
	});

	test("shows every per-account kick outcome after a bulk request", async ({
		page,
		context,
	}) => {
		const kickRequests: KickRequest[] = [];
		await stubDoctorReport(page);
		await stubDoctorKick(
			page,
			[
				{
					discordUserId: "discord-unknown",
					outcome: "kicked",
					reason: null,
					error: null,
				},
				{
					discordUserId: "discord-left",
					outcome: "already_left",
					reason: null,
					error: null,
				},
				{
					discordUserId: "discord-refused",
					outcome: "refused",
					reason: "protected member",
					error: null,
				},
				{
					discordUserId: "discord-failed",
					outcome: "failed",
					reason: null,
					error: "Missing Permissions",
				},
			],
			kickRequests,
		);
		await loginAsUser(context, admin.email);
		await page.goto("/dashboard/discord-doctor");
		await page.getByRole("tab", { name: "Unrecognized 4" }).click();
		await page
			.getByRole("button", { name: "Kick all unrecognized", exact: true })
			.click();
		await page
			.getByRole("alertdialog")
			.getByRole("button", { name: "Kick 4 accounts", exact: true })
			.click();

		await expect
			.poll(() => kickRequests)
			.toEqual([
				{
					discordUserIds: [
						"discord-unknown",
						"discord-left",
						"discord-refused",
						"discord-failed",
					],
				},
			]);
		const latestResults = page.getByRole("region", {
			name: "Latest kick results",
			exact: true,
		});
		for (const outcome of ["Kicked", "Already left", "Refused", "Failed"]) {
			await expect(
				latestResults.getByText(outcome, { exact: true }),
			).toBeVisible();
		}
		await expect(
			latestResults.getByText("Missing Permissions", { exact: true }),
		).toBeVisible();
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
