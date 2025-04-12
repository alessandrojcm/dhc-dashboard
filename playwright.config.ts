import { defineConfig } from '@playwright/test';
import { resolve } from 'path';

export default defineConfig({
	use: {
		launchOptions: {
			args: ['--start-maximized']
		}
	},
	projects: [
		{
			name: 'chromium',
			use: {
				browserName: 'chromium',
				baseURL: 'http://127.0.0.1:8787',
				viewport: null
			}
		},
		{
			name: 'firefox',
			use: {
				browserName: 'firefox',
				baseURL: 'http://127.0.0.1:8787',
				viewport: null
			}
		}
	],
	testDir: 'e2e',
	globalSetup: resolve('./e2e/global-setup'),
	globalTeardown: resolve('./e2e/global-setup')
});
