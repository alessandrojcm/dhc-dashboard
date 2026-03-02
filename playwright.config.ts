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
				baseURL: 'https://127.0.0.1:5173',
				viewport: null
			}
		},
		{
			name: 'firefox',
			use: {
				browserName: 'firefox',
				baseURL: 'https://127.0.0.1:5173',
				viewport: null
			}
		}
	],
	testDir: 'e2e',
	globalSetup: resolve('./e2e/global-setup'),
	globalTeardown: resolve('./e2e/global-setup')
});
