import { expect, test } from "@playwright/test";

// ALE-270: PWA shell — installable manifest + shell-caching service worker.
// These tests run against the dev server (SW convention is production-only),
// so they assert on the served HTML, the static manifest, and installability
// basics. The service-worker bundle itself is verified by `pnpm build`.

test.describe("PWA shell", () => {
	test("served HTML links the manifest and declares theme color", async ({
		page,
	}) => {
		const response = await page.goto("/");
		expect(response?.status()).toBe(200);

		const manifestLink = page.locator(
			'link[rel="manifest"][href*="manifest.webmanifest"]',
		);
		await expect(manifestLink).toHaveCount(1);

		await expect(
			page.locator('meta[name="theme-color"][content="#1F4F85"]'),
		).toHaveCount(1);

		await expect(
			page.locator(
				'link[rel="apple-touch-icon"][href*="apple-touch-icon.png"]',
			),
		).toHaveCount(1);
	});

	test("/manifest.webmanifest is served with a manifest content type", async ({
		request,
	}) => {
		const response = await request.get("/manifest.webmanifest");
		expect(response.status()).toBe(200);
		expect(response.headers()["content-type"]).toContain("manifest");

		const manifest = await response.json();
		expect(manifest.name).toBeTruthy();
		expect(manifest.short_name).toBeTruthy();
		expect(manifest.display).toBe("standalone");
		expect(manifest.start_url).toBe("/");
		expect(manifest.theme_color).toBe("#1F4F85");
		expect(Array.isArray(manifest.icons)).toBeTruthy();
	});

	test("manifest icons resolve and include a maskable 512px entry", async ({
		request,
	}) => {
		const manifestResponse = await request.get("/manifest.webmanifest");
		const manifest = await manifestResponse.json();

		expect(manifest.icons.length).toBeGreaterThan(0);

		const iconResponses = await Promise.all(
			manifest.icons.map((icon: { src: string }) =>
				request.get(icon.src).then((r) => ({ icon, r })),
			),
		);
		for (const { icon, r } of iconResponses) {
			expect(r.status(), `icon ${icon.src}`).toBe(200);
		}

		expect(
			manifest.icons.some(
				(icon: { sizes: string; purpose?: string }) =>
					icon.purpose === "maskable" && icon.sizes === "512x512",
			),
		).toBeTruthy();
	});
});
