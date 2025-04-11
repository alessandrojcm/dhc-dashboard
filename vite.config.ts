import { sentrySvelteKit } from '@sentry/sveltekit';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
	plugins: [
		sentrySvelteKit({
			sourceMapsUploadOptions: {
				org: 'dublin-hema-club',
				project: 'javascript-sveltekit'
			}
		}),
		sveltekit(),
		tailwindcss()
	],
	test: {
		include: ['src/**/*.{test,spec}.{js,ts}']
	}
});
