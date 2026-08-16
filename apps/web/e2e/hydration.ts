import type { Page } from "@playwright/test";

export async function gotoHydrated(page: Page, path: string) {
	const response = await page.goto(path);
	await page
		.locator('[data-app-hydrated="true"]')
		.waitFor({ state: "attached" });
	return response;
}
