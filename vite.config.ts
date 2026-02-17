import { sentrySvelteKit } from '@sentry/sveltekit';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';
import tailwindcss from '@tailwindcss/vite';
import { enhancedImages } from '@sveltejs/enhanced-img';
import { sentryVitePlugin } from '@sentry/vite-plugin';

export default defineConfig({
	assetsInclude: ['src/assets/**/*'],
	plugins: [
		sentrySvelteKit({
			debug: true,
			autoUploadSourceMaps: true,
			org: 'dublin-hema-club',
			project: 'dhc-dashboard',
			authToken: process.env.SENTRY_AUTH_TOKEN,
			sourcemaps: {
				filesToDeleteAfterUpload: ['./svelte-kit/output/**/*.map'],
				assets: ['./svelte-kit/output/**/*.map']
			},
			adapter: 'cloudflare'
		}),
		enhancedImages(),
		sveltekit(),
		tailwindcss(),
		sentryVitePlugin({
			org: 'dublin-hema-club',
			project: 'dhc-dashboard',
			authToken: process.env.SENTRY_AUTH_TOKEN
		})
	],
	build: {
		rollupOptions: {
			external: ['cloudflare:workers']
		},
		sourcemap: true
	},
	test: {
		include: ['src/**/*.{test,spec}.{js,ts}']
	},
	server: {
		watch: {
			ignored: ['**/supabase/**']
		}
	}
});
