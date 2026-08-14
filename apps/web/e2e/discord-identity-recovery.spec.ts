import { expect, test } from "@playwright/test";
import { completeIdentityRecovery, seedE2EScenario } from "./e2eApi";

test.describe.configure({ timeout: 60_000 });

for (const operation of ["replacement", "transfer"] as const) {
	test(`completes a dual-controlled Discord identity ${operation} without signing in`, async ({
		context,
		page,
	}) => {
		const recovery = await seedE2EScenario("identityRecovery", { operation });

		await page.goto(recovery.proofUrl);

		await expect(
			page.getByRole("heading", { name: "Discord identity recovery" }),
		).toBeVisible();
		await expect(page.getByText("Proof received")).toBeVisible();
		await expect(
			page.getByText(`Recovery case ${recovery.caseReference}`),
		).toBeVisible();
		await expect(page.getByText("Recovery never signs you in.")).toBeVisible();

		const cookies = await context.cookies();
		expect(cookies.some((cookie) => cookie.name === "_dhc_session")).toBe(
			false,
		);

		expect(await completeIdentityRecovery(recovery.caseReference)).toEqual({
			state: "completed",
			operation,
			activeDestinationPrincipalId: recovery.destinationPrincipalId,
			bindingHistoryCount: 1,
			affectedTokenCount: 0,
		});
	});
}
