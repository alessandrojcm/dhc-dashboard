import { expect, test } from "@playwright/test";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";
import { createMember, createUniqueEmail } from "./setupFunctions";

// ALE-299: the Web Push opt-in lives in the notification centre. Playwright's
// Chromium reports notification permission as denied unless a test grants it,
// so a fresh browser here lands on the "blocked" explanation without ever
// prompting. This proves the toggle is wired into the centre and settles
// without a switch; enable/disable decisions are covered by Vitest (workflow
// + component) and the config endpoint and delivery path by the Phoenix suite.

test.describe("ALE-299 notification centre Web Push toggle", () => {
	let memberEmail = "";
	let cleanUp: () => Promise<void> = async () => {};

	test.beforeAll(async () => {
		const member = await createMember({
			email: createUniqueEmail("web-push"),
		});
		memberEmail = member.email;
		cleanUp = () => member.cleanUp();
	});

	test.afterAll(async () => {
		await cleanUp();
	});

	test("explains that notifications are blocked, without a switch", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, memberEmail);
		await gotoHydrated(page, "/dashboard");

		await page.getByRole("button", { name: "Notifications" }).click();

		const toggle = page.getByTestId("web-push-toggle");
		await expect(toggle).toBeVisible();
		// Exact: the blocked explanation also says "...turn push notifications back on".
		await expect(
			toggle.getByText("Push notifications", { exact: true }),
		).toBeVisible();
		await expect(
			toggle.getByText(/Notifications are blocked for this site/),
		).toBeVisible({ timeout: 10_000 });
		await expect(toggle.getByRole("switch")).toHaveCount(0);
	});
});
