import { expect, type Page } from "@playwright/test";

type InvitationCredentials = {
	email: string;
	dateOfBirth: string;
};

type InvitationSignup = InvitationCredentials & {
	invitationId: string;
};

export async function fillInvitationCredentials(
	page: Page,
	credentials: InvitationCredentials,
) {
	await page.getByLabel("Email").fill(credentials.email);
	await page.getByRole("button", { name: "Date of birth" }).click();
	await expect(page.getByLabel("Select a year")).toBeVisible();
	await page
		.getByLabel("Select a year")
		.selectOption(credentials.dateOfBirth.slice(0, 4));
	await page
		.getByLabel("Select a month")
		.selectOption(String(Number(credentials.dateOfBirth.slice(5, 7))));

	const date = new Date(`${credentials.dateOfBirth}T00:00:00Z`);
	const accessibleDay = new Intl.DateTimeFormat("en-US", {
		day: "numeric",
		month: "long",
		timeZone: "UTC",
		weekday: "long",
	}).format(date);
	await page.getByRole("button", { name: `${accessibleDay},` }).click();
}

export async function submitInvitationCredentials(
	page: Page,
	invitation: InvitationSignup,
) {
	await page.goto(`/members/signup/${invitation.invitationId}`);
	await page.waitForLoadState("networkidle");
	await fillInvitationCredentials(page, invitation);
	await page.getByRole("button", { name: /verify invitation/i }).click();
}
