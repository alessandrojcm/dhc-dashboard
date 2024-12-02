import { defineConfig } from '@playwright/test';

export default defineConfig({
	use: {
		launchOptions: {
			args: ["--start-maximized"],
		}
	},
	webServer: {
		command: 'npm run build && npm run preview',
		port: 4173,
		reuseExistingServer: true
	},
	projects: [
		{
			name: 'chromium',
			use: {
				browserName: 'chromium',
				baseURL: 'http://localhost:5173',
				viewport: null
			}
		},
		{
			name: 'firefox',
			use: {
				browserName: 'firefox',
				baseURL: 'http://localhost:5173',
				viewport: null
			}
		}
	],
	testDir: 'e2e'
});
