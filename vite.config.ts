import { sentrySvelteKit } from '@sentry/sveltekit';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';
import tailwindcss from '@tailwindcss/vite';
import { enhancedImages } from '@sveltejs/enhanced-img';

export default defineConfig({
	assetsInclude: ['src/assets/**/*'],
	plugins: [
		sentrySvelteKit({
			sourceMapsUploadOptions: {
				telemetry: false,
				org: 'dublin-hema-club',
				project: 'dhc-dashboard'
			},
			adapter: 'cloudflare'
		}),
		enhancedImages(),
		sveltekit(),
		tailwindcss()
		// analyzer()
	],
	build: {
		rollupOptions: {
			external: ['cloudflare:workers']
		}
	},
	test: {
		include: ['src/**/*.{test,spec}.{js,ts}']
	}
});
