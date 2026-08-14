import { expect, test } from "@playwright/test";
import {
	auditInvitationAcceptance,
	deleteE2EFixture,
	finishInvitationAcceptanceProbe,
	interruptNextOnboardingFinalization,
	seedE2EScenario,
	startOnboardingIsolationProbe,
} from "./e2eApi";
import { fillInvitationCredentials } from "./invitationSignup";
import {
	routeSuccessfulDiscordAcceptance,
	setupInvitedUser,
	stripeClient,
} from "./setupFunctions";

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
		page.getByText(
			"Your membership has been successfully processed. Welcome to Dublin Hema Club! Sign in with your membership email to continue.",
		),
	).toBeVisible();
	await expect(page.getByRole("link", { name: "Sign In" })).toBeVisible();

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
			principalCount: 1,
			userProfileCount: 1,
			memberRoleCount: 1,
			discordIdentityCount: 1,
			memberProfileCount: 1,
			attemptCount: 1,
			provisionedAttemptCount: 0,
			completedAttemptCount: 1,
			declinedAttemptCount: 0,
			continuationCount: 1,
			subjectClaimCount: 0,
			stripeCustomerCount: 1,
			monthlySubscriptionCount: 1,
			annualSubscriptionCount: 1,
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
	let probeFinished = false;
	let testFailed = false;

	page.on("request", (request) => {
		browserRequestPayloads.push(
			`${request.url()}\n${request.postData() ?? ""}`,
		);
		if (request.url().includes("stripe.com"))
			stripeRequests.push(request.url());
	});

	try {
		await startOnboardingIsolationProbe();
		await page.goto(`/members/signup/${invitation.invitationId}`);
		await page.waitForLoadState("networkidle");
		await fillInvitationCredentials(page, invitation);
		await page.getByRole("button", { name: "Verify Invitation" }).click();
		expect(page.url()).not.toContain(invitation.email);
		expect(page.url()).not.toContain(invitation.dateOfBirth);

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
		const proof = cookies.find(
			(cookie) => cookie.name === "_dhc_onboarding_acceptance",
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
		expect(proof.value).not.toContain(invitation.invitationId);
		expect(cookies.some((cookie) => cookie.name === "_dhc_session")).toBe(
			false,
		);

		const isolation = await finishInvitationAcceptanceProbe(
			invitation.invitationId,
		);
		probeFinished = true;
		expect(isolation).toEqual({
			attempts: 1,
			continuations: 1,
			externalIdentities: 0,
			magicLinksOrSessions: 0,
			memberProfiles: 0,
			obanJobs: 0,
			principals: 0,
			roles: 0,
			stripeCustomerId: null,
			stripeInvocations: [],
			stripeState: {},
			userProfiles: 0,
		});

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
		const browserStorage = await page.evaluate(() => ({
			local: Object.entries(localStorage),
			session: Object.entries(sessionStorage),
		}));
		const storageKeys = [
			...browserStorage.local.map(([key]) => key),
			...browserStorage.session.map(([key]) => key),
		];
		const serializedStorage = JSON.stringify(browserStorage);
		expect(storageKeys.join(" ")).not.toMatch(
			/onboarding|acceptance|continuation|attempt/i,
		);
		expect(serializedStorage).not.toContain(invitation.invitationId);
		expect(serializedStorage).not.toContain(invitation.email);
		expect(serializedStorage).not.toContain(invitation.dateOfBirth);
	} catch (error) {
		testFailed = true;
		throw error;
	} finally {
		if (!probeFinished) {
			await finishInvitationAcceptanceProbe(invitation.invitationId).catch(
				() => undefined,
			);
		}
		await deleteE2EFixture("invitation", invitation.invitationId).catch(
			(error) => {
				if (!testFailed) throw error;
			},
		);
	}
});

test("completes a paid Discord-bound Invitation Acceptance without creating auth credentials", async ({
	context,
	page,
}) => {
	const invitation = await setupInvitedUser({
		email: `paid-discord-acceptance-${Date.now()}@example.com`,
		dateOfBirth: new Date("1990-01-01T00:00:00.000Z"),
	});
	const hostedCheckoutRequests: string[] = [];
	page.on("request", (request) => {
		if (request.url().includes("checkout.stripe"))
			hostedCheckoutRequests.push(request.url());
	});

	try {
		await reachDiscordVerified(page, {
			invitationId: invitation.invitationId,
			email: invitation.email,
			dateOfBirth: invitation.date_of_birth.format("YYYY-MM-DD"),
		});
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
		await invitation.cleanUp();
	}
});

test("recovers a real Stripe acceptance interrupted before local finalization", async ({
	context,
	page,
}) => {
	const invitation = await setupInvitedUser();

	try {
		await reachDiscordVerified(page, {
			invitationId: invitation.invitationId,
			email: invitation.email,
			dateOfBirth: invitation.date_of_birth.format("YYYY-MM-DD"),
		});
		await fillMembershipPayment(
			page,
			invitation,
			"Katherine Johnson",
			"0838774532",
		);
		await interruptNextOnboardingFinalization();
		await page.getByRole("button", { name: "Sign up" }).click();

		await expect
			.poll(() => auditInvitationAcceptance(invitation.invitationId), {
				timeout: 30_000,
			})
			.toMatchObject({
				principalCount: 0,
				attemptCount: 1,
				provisionedAttemptCount: 1,
				stripeCustomerCount: 1,
				monthlySubscriptionCount: 1,
				annualSubscriptionCount: 1,
			});
		await page.reload();
		await expect(
			page.getByRole("heading", { name: "Payment in progress" }),
		).toBeVisible();
		await expect(
			page.getByText(
				"Your Discord account remains verified. You will not need to connect it again.",
			),
		).toBeVisible();
		await expect(
			page.getByRole("link", { name: "Retry completion" }),
		).toBeVisible();

		expect(await auditInvitationAcceptance(invitation.invitationId)).toEqual({
			sessionTokenCount: 0,
			magicLinkTokenCount: 0,
			principalCount: 0,
			userProfileCount: 0,
			memberRoleCount: 0,
			discordIdentityCount: 0,
			memberProfileCount: 0,
			attemptCount: 1,
			provisionedAttemptCount: 1,
			completedAttemptCount: 0,
			declinedAttemptCount: 0,
			continuationCount: 1,
			subjectClaimCount: 1,
			stripeCustomerCount: 1,
			monthlySubscriptionCount: 1,
			annualSubscriptionCount: 1,
		});

		await page.getByRole("link", { name: "Retry completion" }).click();
		await expectUnsignedCompletedAcceptance(
			page,
			context,
			invitation.invitationId,
		);

		const customers = await stripeClient.customers.list({
			email: invitation.email,
			limit: 2,
		});
		expect(customers.data).toHaveLength(1);
		const subscriptions = await stripeClient.subscriptions.list({
			customer: customers.data[0].id,
			status: "all",
			limit: 10,
		});
		expect(subscriptions.data).toHaveLength(2);
	} finally {
		await invitation.cleanUp();
	}
});

test("completes a complimentary Discord-bound Invitation Acceptance without auth credentials", async ({
	context,
	page,
}) => {
	const invitation = await setupInvitedUser({
		email: `complimentary-discord-acceptance-${Date.now()}@example.com`,
		dateOfBirth: new Date("1990-01-01T00:00:00.000Z"),
	});
	const coupon = await stripeClient.coupons.create({
		percent_off: 100,
		duration: "forever",
		name: "Protected acceptance complimentary E2E",
	});
	const promotion = await stripeClient.promotionCodes.create({
		promotion: { coupon: coupon.id, type: "coupon" },
		code: `COMPLIMENTARY-${Date.now()}`,
		max_redemptions: 2,
	});

	try {
		await reachDiscordVerified(page, {
			invitationId: invitation.invitationId,
			email: invitation.email,
			dateOfBirth: invitation.date_of_birth.format("YYYY-MM-DD"),
		});
		await fillMembershipPayment(
			page,
			invitation,
			"Ada Lovelace",
			"0838774532",
			promotion.code,
		);
		await page.getByRole("button", { name: "Sign up" }).click();

		await expectUnsignedCompletedAcceptance(
			page,
			context,
			invitation.invitationId,
		);
	} finally {
		try {
			await stripeClient.promotionCodes.update(promotion.id, { active: false });
			await stripeClient.coupons.del(coupon.id);
		} finally {
			await invitation.cleanUp();
		}
	}
});
