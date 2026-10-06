import { sentrySvelteKit } from "@sentry/sveltekit/vite";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vitest/config";
import tailwindcss from "@tailwindcss/vite";
import { enhancedImages } from "@sveltejs/enhanced-img";
import { sentryVitePlugin } from "@sentry/vite-plugin";
import mkcert from "vite-plugin-mkcert";
import { playwright } from "@vitest/browser-playwright";
import adapter from "@sveltejs/adapter-cloudflare";
import { cloudflareCreateRequire } from "./tools/cloudflare-create-require.js";

export default defineConfig(({ command }) => ({
	envDir: "../..",
	assetsInclude: ["src/assets/**/*"],
	plugins: [
		cloudflareCreateRequire(),
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
		sveltekit({
			adapter: adapter(),
			// Same directory as Vite's `envDir`: SvelteKit 3 loads and validates
			// `src/env.ts` variables from its own `env.dir`, not from `envDir`.
			env: {
				dir: "../..",
			},
			compilerOptions: {
				experimental: {
					async: true,
				},
			},
			experimental: {
				remoteFunctions: true,
			},
			tracing: {
				server: true,
			},
		}),
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
		rolldownOptions: {
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
					include: ["src/**/*.{test,spec}.{js,ts}", "tools/**/*.test.ts"],
					exclude: ["src/**/*.browser.{test,spec}.{js,ts}"],
				},
			},
			{
				extends: true,
				test: {
					name: "browser",
					include: ["src/**/*.browser.{test,spec}.{js,ts}"],
					setupFiles: [
						"vitest-browser-svelte",
						"./src/vitest-browser-setup.ts",
					],
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
		host: "127.0.0.1",
		watch: {
			ignored: ["**/supabase/**"],
		},
	},
}));
