import { expect, test } from "@playwright/test";
import * as v from "valibot";
import { loginAsUser } from "./auth";
import { API_BASE_URL } from "./e2eApi";
import { gotoHydrated } from "./hydration";
import { createMember, createUniqueEmail } from "./setupFunctions";

// ALE-299: the Web Push opt-in lives in the notification centre. Headless
// Chromium has no push service to subscribe against, so this covers what a
// browser can show before any permission prompt: the toggle renders inside
// the centre, settles on an explained state, and never flips itself on. The
// enable/disable decisions are covered by Vitest (workflow + component) and
// the delivery path by the Phoenix suite.

const settledStates = [
	"server-disabled",
	"ios-install-required",
	"unsupported",
	"denied",
	"off",
	"error",
];

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

	test("renders in the notification centre with an explained, settled state", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, memberEmail);
		await gotoHydrated(page, "/dashboard");

		await page.getByRole("button", { name: "Notifications" }).click();

		const toggle = page.getByTestId("web-push-toggle");
		await expect(toggle).toBeVisible();
		await expect(toggle.getByText("Push notifications")).toBeVisible();

		// Loading resolves to one explained state; nothing here is a prompt.
		await expect
			.poll(async () => toggle.getAttribute("data-status"), { timeout: 10_000 })
			.not.toBe("loading");
		const status = await toggle.getAttribute("data-status");
		expect(settledStates).toContain(status);

		// A fresh browser is never opted in on its own.
		const pushSwitch = toggle.getByRole("switch", {
			name: /push notifications/i,
		});
		if ((await pushSwitch.count()) > 0) {
			await expect(pushSwitch).toHaveAttribute("aria-checked", "false");
		}
	});

	test("the push config endpoint exposes only the public key", async ({
		context,
	}) => {
		await loginAsUser(context, memberEmail);

		// `context.request` carries the `_dhc_session` cookie the login added.
		const response = await context.request.get(
			`${API_BASE_URL}/notifications/push/config`,
		);
		expect(response.status()).toBe(200);

		const body = v.parse(
			v.object({
				data: v.strictObject({
					enabled: v.boolean(),
					vapidPublicKey: v.nullable(v.string()),
				}),
			}),
			await response.json(),
		);
		// `strictObject` fails the parse on any extra key, so a leaked endpoint
		// or private key would show up as a schema error here.
		expect(body.data.enabled === !!body.data.vapidPublicKey).toBe(true);
	});
});
