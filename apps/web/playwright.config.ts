import { defineConfig } from "@playwright/test";
import { fileURLToPath } from "node:url";
import { resolve } from "path";

const rootDir = fileURLToPath(new URL("../..", import.meta.url));

export default defineConfig({
	use: {
		ignoreHTTPSErrors: true,
		launchOptions: {
			args: ["--start-maximized"],
		},
	},
	workers: 1,
	reporter: [
		["list"],
		["html", { outputFolder: "playwright-report", open: "never" }],
		["json", { outputFile: "test-results/playwright-results.json" }],
	],
	webServer: [
		{
			command: "mise run e2e-phoenix-server",
			cwd: rootDir,
			url: "http://127.0.0.1:4000/api/health",
			name: "phoenix-e2e",
			timeout: 120_000,
			reuseExistingServer: false,
		},
		{
			command: "mise run e2e-web-server",
			cwd: rootDir,
			url: "http://127.0.0.1:5173",
			name: "sveltekit-e2e",
			timeout: 120_000,
			reuseExistingServer: !process.env.CI,
		},
	],
	projects: [
		{
			name: "chromium",
			use: {
				browserName: "chromium",
				baseURL: "http://127.0.0.1:5173",
				viewport: null,
			},
		},
		// {
		// 	name: "firefox",
		// 	use: {
		// 		browserName: "firefox",
		// 		baseURL: "http://127.0.0.1:5173",
		// 		viewport: null,
		// 	},
		// },
	],
	testDir: "e2e",
	globalSetup: resolve("./e2e/global-setup"),
	globalTeardown: resolve("./e2e/global-teardown"),
});
