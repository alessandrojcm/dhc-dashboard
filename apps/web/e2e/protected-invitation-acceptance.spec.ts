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
	const browserRequestPayloads: string[] = [];
	await page.route(
		`**/members/signup/${invitation.invitationId}/discord`,
		async (route) => {
			const response = await route.fetch({ maxRedirects: 0 });
			expect(response.status()).toBe(302);
			const authorizationUrl = new URL(response.headers().location);
			expect(authorizationUrl.origin + authorizationUrl.pathname).toBe(
				"https://discord.example.com/oauth2/authorize",
			);
			expect(authorizationUrl.searchParams.get("redirect_uri")).toBe(
				"http://127.0.0.1:5173/auth/discord/acceptance/callback",
			);
			await route.fulfill({
				response,
				headers: {
					...response.headers(),
					location:
						"http://127.0.0.1:5173/auth/discord/acceptance/callback?state=test-state&code=success",
				},
			});
		},
	);

	page.on("request", (request) => {
		browserRequestPayloads.push(
			`${request.url()}\n${request.postData() ?? ""}`,
		);
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
		if (!proof) throw new Error("Missing protected acceptance proof cookie");
		expect(proof.value).toMatch(
			/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
		);
		const forbiddenStorageFragments = [
			proof.name,
			proof.value,
			"_dhc_key",
			"_dhc_session",
		];
		const browserStorageText = () =>
			page.evaluate(() =>
				[localStorage, sessionStorage]
					.flatMap((storage) =>
						Object.keys(storage).flatMap((key) => [
							key,
							storage.getItem(key) ?? "",
						]),
					)
					.join("\n"),
			);
		expect(cookies.some((cookie) => cookie.name === "_dhc_session")).toBe(
			false,
		);

		await page.reload();
		await expect(
			page.getByRole("heading", { name: "Connect Discord" }),
		).toBeVisible();
		const awaitingDiscordStorage = await browserStorageText();
		for (const fragment of forbiddenStorageFragments)
			expect(awaitingDiscordStorage).not.toContain(fragment);

		await page.getByRole("link", { name: "Continue to Discord" }).click();
		await expect(
			page.getByRole("heading", { name: "Discord verified" }),
		).toBeVisible();
		await expect(
			page.getByText("Verified Discord account: @request-member"),
		).toBeVisible();
		expect(page.url()).toBe(
			`http://127.0.0.1:5173/members/signup/${invitation.invitationId}`,
		);
		expect(stripeRequests).toEqual([]);
		expect(
			(await context.cookies()).some(
				(cookie) => cookie.name === "_dhc_session",
			),
		).toBe(false);
		expect(
			(await context.cookies()).some((cookie) => cookie.name === "_dhc_key"),
		).toBe(false);

		await page.reload();
		await expect(
			page.getByRole("heading", { name: "Discord verified" }),
		).toBeVisible();
		const verifiedDiscordStorage = await browserStorageText();
		for (const fragment of forbiddenStorageFragments)
			expect(verifiedDiscordStorage).not.toContain(fragment);
		const browserRequestText = browserRequestPayloads.join("\n");
		for (const fragment of forbiddenStorageFragments)
			expect(browserRequestText).not.toContain(fragment);

		await page
			.getByRole("button", { name: "Use a different Discord account" })
			.click();
		await expect(
			page.getByRole("button", { name: "Verify Invitation" }),
		).toBeVisible();
		expect(stripeRequests).toEqual([]);
		expect(
			(await context.cookies()).some((cookie) =>
				cookie.name.startsWith("onboarding-acceptance-"),
			),
		).toBe(false);
	} finally {
		await deleteE2EFixture("invitation", invitation.invitationId);
	}
});
