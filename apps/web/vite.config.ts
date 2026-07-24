import { sentrySvelteKit } from "@sentry/sveltekit";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vitest/config";
import tailwindcss from "@tailwindcss/vite";
import { enhancedImages } from "@sveltejs/enhanced-img";
import { sentryVitePlugin } from "@sentry/vite-plugin";
import mkcert from "vite-plugin-mkcert";
import { playwright } from "@vitest/browser-playwright";

export default defineConfig(({ command }) => ({
	envDir: "../..",
	assetsInclude: ["src/assets/**/*"],
	plugins: [
		sentrySvelteKit({
			debug: command === "serve",
			autoUploadSourceMaps: true,
			org: "dublin-hema-club",
			project: "dhc-dashboard",
			authToken: process.env.SENTRY_AUTH_TOKEN,
			sourcemaps: {
				filesToDeleteAfterUpload: ["./svelte-kit/output/**/*.map"],
				assets: ["./svelte-kit/output/**/*.map"],
			},
			adapter: "cloudflare",
		}),
		sveltekit(),
		enhancedImages(),
		tailwindcss(),
		sentryVitePlugin({
			org: "dublin-hema-club",
			project: "dhc-dashboard",
			authToken: process.env.SENTRY_AUTH_TOKEN,
		}),
		...(process.env.E2E_SERVER === "true" ? [] : [mkcert()]),
	],
	build: {
		rollupOptions: {
			external: ["cloudflare:workers"],
		},
		sourcemap: true,
	},
	test: {
		projects: [
			{
				extends: true,
				test: {
					name: "unit",
					include: ["src/**/*.{test,spec}.{js,ts}"],
					exclude: ["src/**/*.browser.{test,spec}.{js,ts}"],
				},
			},
			{
				extends: true,
				test: {
					name: "browser",
					include: ["src/**/*.browser.{test,spec}.{js,ts}"],
					setupFiles: ["vitest-browser-svelte"],
					browser: {
						enabled: true,
						headless: true,
						provider: playwright(),
						instances: [{ browser: "chromium" }],
					},
				},
			},
		],
	},
	server: {
		watch: {
			ignored: ["**/supabase/**"],
		},
	},
}));
