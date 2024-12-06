import { test as base, Page } from '@playwright/test';
import { getSupabaseServiceClient } from './setupFunctions';

export const test = base.extend<{ email: string; password: string; signIn: Page }>({
    email: 'test@test.com',
    password: 'password',
	signIn: async ({ browser, email, password }, use) => {
		const client = getSupabaseServiceClient();

		const { data, error } = await client.auth.signInWithPassword({
			email: email,
			password: password
		});

		const authContext = await browser.newContext();
		await authContext.addCookies([
			{
				name: 'sb-127-auth-token.0',
				value: encodeURIComponent(JSON.stringify(data.session ?? {})),
				secure: true,
				domain: 'localhost',
				path: '/',
				sameSite: 'Lax'
			}
		]);
        const authPage = await authContext.newPage();
        await use(authPage)
	}
});

export { expect } from '@playwright/test';
