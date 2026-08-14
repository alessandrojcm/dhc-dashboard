import { expect, test } from "@playwright/test";
import {
	auditInvitationAcceptance,
	deleteE2EFixture,
	seedE2EScenario,
} from "./e2eApi";

test.describe.configure({ timeout: 60_000 });

function getStripeFrame(page: import("@playwright/test").Page) {
	return page.locator(".__PrivateStripeElement").frameLocator("iframe");
}

async function fillMembershipPayment(
	page: import("@playwright/test").Page,
	invitation: { email: string },
	nextOfKin: string,
	phone: string,
	couponCode?: string,
) {
	await expect(page.locator("#payment-element-state")).toHaveAttribute(
		"data-ready",
		"true",
	);
	await page.getByLabel("Next of Kin", { exact: true }).fill(nextOfKin);
	const phoneInput = page.getByLabel("Next of Kin Phone Number");
	await phoneInput.pressSequentially(phone, { delay: 50 });
	await phoneInput.press("Tab");

	if (couponCode) {
		await page
			.getByRole("button", { name: "Have a promotional code?" })
			.click();
		await page.getByPlaceholder("Enter promotional code").fill(couponCode);
		await page.getByRole("button", { name: "Apply Code" }).click();
		await expect(page.getByText(`Code ${couponCode} applied`)).toBeVisible();
	}

	const stripeFrame = getStripeFrame(page);
	await expect(stripeFrame.getByLabel("IBAN")).toBeVisible({
		timeout: 15_000,
	});
	await stripeFrame.getByLabel("IBAN").fill("IE29AIBK93115212345678");
	await stripeFrame.getByLabel("Email").fill(invitation.email);
	await stripeFrame.getByLabel("Full name").fill(nextOfKin);
	await stripeFrame.getByLabel("Address line 1").fill("123 Main Street");
	await stripeFrame.getByLabel("Country or region").selectOption("Ireland");
	await stripeFrame.getByLabel("City").fill("Dublin");
	await stripeFrame.getByLabel("Eircode").fill("K45 HR22");
	await stripeFrame.getByLabel("County").selectOption("Dublin");
	await expect(page.locator("#payment-element-state")).toHaveAttribute(
		"data-complete",
		"true",
	);
}

async function routeSuccessfulDiscordAcceptance(
	page: import("@playwright/test").Page,
	invitationId: string,
) {
	await page.route(
		`**/members/signup/${invitationId}/discord`,
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
}

async function reachDiscordVerified(
	page: import("@playwright/test").Page,
	invitation: {
		invitationId: string;
		email: string;
		dateOfBirth: string;
	},
) {
	await routeSuccessfulDiscordAcceptance(page, invitation.invitationId);
	await page.goto(
		`/members/signup/${invitation.invitationId}?email=${encodeURIComponent(invitation.email)}&dateOfBirth=${invitation.dateOfBirth}`,
	);
	await page.getByRole("button", { name: "Verify Invitation" }).click();
	await page.getByRole("link", { name: "Continue to Discord" }).click();
	await expect(
		page.getByRole("heading", { name: "Discord verified" }),
	).toBeVisible();
}

async function expectUnsignedCompletedAcceptance(
	page: import("@playwright/test").Page,
	context: import("@playwright/test").BrowserContext,
	invitationId: string,
) {
	await expect(page).toHaveURL(
		`http://127.0.0.1:5173/members/signup/${invitationId}/success`,
		{ timeout: 30_000 },
	);
	await expect(
		page.getByText("Your membership has been created."),
	).toBeVisible();
	await expect(page.getByText("You are not signed in.")).toBeVisible();
	await expect(page.getByRole("link", { name: "Go to sign in" })).toBeVisible();

	const cookies = await context.cookies();
	expect(cookies.some((cookie) => cookie.name === "_dhc_session")).toBe(false);
	expect(cookies.some((cookie) => cookie.name === "_dhc_key")).toBe(false);
	expect(
		cookies.some((cookie) => cookie.name.startsWith("onboarding-acceptance-")),
	).toBe(false);

	await expect
		.poll(() => auditInvitationAcceptance(invitationId))
		.toEqual({
			sessionTokenCount: 0,
			magicLinkTokenCount: 0,
			discordIdentityCount: 1,
			memberProfileCount: 1,
		});
}

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
	await routeSuccessfulDiscordAcceptance(page, invitation.invitationId);

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
			path: "/",
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
		expect(
			(await context.cookies()).some((cookie) =>
				cookie.name.startsWith("onboarding-acceptance-"),
			),
		).toBe(false);
	} finally {
		await deleteE2EFixture("invitation", invitation.invitationId);
	}
});

test("completes a paid Discord-bound Invitation Acceptance without creating auth credentials", async ({
	context,
	page,
}) => {
	const invitation = await seedE2EScenario("invitation", {
		email: `paid-discord-acceptance-${Date.now()}@example.com`,
		firstName: "Ada",
		lastName: "Lovelace",
		phoneNumber: "+353810000000",
		dateOfBirth: "1990-01-01",
		status: "pending",
	});
	const hostedCheckoutRequests: string[] = [];
	page.on("request", (request) => {
		if (request.url().includes("checkout.stripe"))
			hostedCheckoutRequests.push(request.url());
	});

	try {
		await reachDiscordVerified(page, invitation);
		await fillMembershipPayment(page, invitation, "Grace Hopper", "0838774532");
		expect(
			(await context.cookies()).some((cookie) =>
				cookie.name.startsWith("onboarding-acceptance-"),
			),
		).toBe(true);
		const signUpButton = page.getByRole("button", { name: "Sign up" });
		const formValues = await signUpButton.evaluate((button) => {
			const form = (button as HTMLButtonElement).form;
			return form ? Object.fromEntries(new FormData(form)) : null;
		});
		expect(formValues).toMatchObject({
			nextOfKin: "Grace Hopper",
			nextOfKinNumber: "+353838774532",
		});
		await signUpButton.click();

		await expectUnsignedCompletedAcceptance(
			page,
			context,
			invitation.invitationId,
		);
		expect(hostedCheckoutRequests).toEqual([]);
	} finally {
		await deleteE2EFixture("invitation", invitation.invitationId);
	}
});

test("completes a complimentary Discord-bound Invitation Acceptance without auth credentials", async ({
	context,
	page,
}) => {
	const invitation = await seedE2EScenario("invitation", {
		email: `complimentary-discord-acceptance-${Date.now()}@example.com`,
		firstName: "Grace",
		lastName: "Hopper",
		phoneNumber: "+353810000000",
		dateOfBirth: "1990-01-01",
		status: "pending",
	});
	try {
		await reachDiscordVerified(page, invitation);
		await fillMembershipPayment(
			page,
			invitation,
			"Ada Lovelace",
			"0838774532",
			"COMPLIMENTARY",
		);
		await page.getByRole("button", { name: "Sign up" }).click();

		await expectUnsignedCompletedAcceptance(
			page,
			context,
			invitation.invitationId,
		);
	} finally {
		await deleteE2EFixture("invitation", invitation.invitationId);
	}
});
