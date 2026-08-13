import { expect, test } from "@playwright/test";
import { deleteE2EFixture, seedE2EScenario } from "./e2eApi";

test("starts a protected Invitation Acceptance without starting Stripe or a dashboard session", async ({
	context,
	page,
}) => {
	const invitation = await seedE2EScenario("invitation", {
		email: `protected-acceptance-${Date.now()}@example.com`,
		firstName: "Ada",
		lastName: "Lovelace",
		phoneNumber: "+353810000000",
		dateOfBirth: "1990-01-01",
		status: "pending",
	});
	const stripeRequests: string[] = [];

	page.on("request", (request) => {
		if (request.url().includes("stripe.com"))
			stripeRequests.push(request.url());
	});

	try {
		await page.goto(
			`/members/signup/${invitation.invitationId}?email=${encodeURIComponent(invitation.email)}&dateOfBirth=${invitation.dateOfBirth}`,
		);
		await page.getByRole("button", { name: "Verify Invitation" }).click();

		await expect(page.getByText("Create your membership")).toBeVisible();
		await expect(
			page.getByRole("heading", { name: "Connect Discord" }),
		).toBeVisible();
		await expect(
			page.getByText(
				"Your membership has not been created and no payment has started.",
			),
		).toBeVisible();
		expect(stripeRequests).toEqual([]);
		const cookies = await context.cookies();
		const proof = cookies.find((cookie) =>
			cookie.name.startsWith("onboarding-acceptance-"),
		);
		expect(proof).toMatchObject({
			httpOnly: true,
			path: `/members/signup/${invitation.invitationId}`,
			sameSite: "Lax",
		});
		expect(proof?.value).toMatch(
			/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
		);
		expect(cookies.some((cookie) => cookie.name === "_dhc_session")).toBe(
			false,
		);

		await page.reload();
		await expect(
			page.getByRole("heading", { name: "Connect Discord" }),
		).toBeVisible();
		await expect(
			page.evaluate(() => ({
				local: localStorage.length,
				session: sessionStorage.length,
			})),
		).resolves.toEqual({ local: 0, session: 0 });
	} finally {
		await deleteE2EFixture("invitation", invitation.invitationId);
	}
});
