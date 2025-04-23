import { sentrySvelteKit } from "@sentry/sveltekit";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vitest/config";
import tailwindcss from "@tailwindcss/vite";
import { enhancedImages } from "@sveltejs/enhanced-img";

export default defineConfig({
	assetsInclude: ["src/assets/**/*"],
	plugins: [
		sentrySvelteKit({
			debug: true,
			sourceMapsUploadOptions: {
				org: "dublin-hema-club",
				project: "dhc-dashboard",
				authToken: process.env.SENTRY_AUTH_TOKEN,
			},
			sourcemaps: {
				filesToDeleteAfterUpload: ["./svelte-kit/output/**/*.map"],
				assets: ["./svelte-kit/output/**/*.map"]
			},
			adapter: "cloudflare",
		}),
		enhancedImages(),
		sveltekit(),
		tailwindcss(),
		// analyzer()
	],
	build: {
		rollupOptions: {
			external: ["cloudflare:workers"],
		},
		sourcemap: true,
	},
	test: {
		include: ["src/**/*.{test,spec}.{js,ts}"],
	},
});
