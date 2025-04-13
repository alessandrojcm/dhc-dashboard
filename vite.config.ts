import { sentrySvelteKit } from '@sentry/sveltekit';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
	plugins: [
		sentrySvelteKit({
			sourceMapsUploadOptions: {
				telemetry: false,
				org: 'dublin-hema-club',
				project: 'dhc-dasboard'
			},
			adapter: 'cloudflare'
		}),
		sveltekit(),
		tailwindcss()
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
