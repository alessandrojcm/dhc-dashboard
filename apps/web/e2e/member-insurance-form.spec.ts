import { expect, test } from "@playwright/test";
import { seedE2EScenario } from "./e2eApi";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";

declare global {
	interface Window {
		__openedUrls: string[];
	}
}

// Verifies the member-detail profile page reads the insurance form link through
// the Phoenix API (GET /api/members/insurance-form) after the PostgREST read
// migration. Requires the Phoenix dev server (mise run phx-server) to be
// reachable at the configured API_BASE_URL alongside the SvelteKit dev server.
test.describe("Member insurance form link", () => {
	let testData: Awaited<ReturnType<typeof createMember>>;
	const insuranceFormUrl = `https://example.com/hema-insurance-${Date.now()}`;

	test.beforeAll(async () => {
		testData = await createMember({
			email: `insurance-${Date.now()}@test.com`,
			roles: new Set(["member"]),
		});
	});

	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, testData.email);
	});

	test.afterAll(async () => {
		// Restore the baseline empty value seeded in global-setup.
		await seedE2EScenario("setting", {
			key: "hema_insurance_form_link",
			value: "https://example.com/insurance",
		});

		await testData?.cleanUp();
	});

	test("renders the insurance form link on the member profile via Phoenix", async ({
		page,
	}) => {
		// Seed the insurance form link the Phoenix endpoint reads. Set immediately
		// before navigating to minimise the shared-settings interference window.
		await seedE2EScenario("setting", {
			key: "hema_insurance_form_link",
			value: insuranceFormUrl,
		});

		await gotoHydrated(page, `/dashboard/members/${testData.userId}`);

		// The "Open insurance form" button only renders when the Phoenix read
		// returns a non-null link, so visibility proves the read works end-to-end.
		const button = page.getByRole("button", { name: /open insurance form/i });
		await expect(button).toBeVisible();

		// Stub window.open so clicking does not navigate, then assert the seeded
		// URL flows through Phoenix -> load -> button click. This guards against
		// shared-settings interference from other specs mutating the same row.
		await page.evaluate(() => {
			window.__openedUrls = [];
			window.open = (url) => {
				window.__openedUrls.push(String(url));
				return null;
			};
		});
		await button.click();

		const openedUrls = await page.evaluate(() => window.__openedUrls);
		expect(openedUrls).toEqual([insuranceFormUrl]);
	});
});
