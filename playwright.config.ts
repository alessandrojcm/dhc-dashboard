import { defineConfig } from '@playwright/test';

export default defineConfig({
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
				baseURL: 'http://localhost:5173'
			}
		},
		{
			name: 'firefox',
			use: {
				browserName: 'firefox',
				baseURL: 'http://localhost:5173'
			}
		}
	],
	testDir: 'e2e'
});
