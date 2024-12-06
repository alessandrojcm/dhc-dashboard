import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { getSupabaseServiceClient } from './setupFunctions';

// For base64 encoding in Node environment
const btoa = (str: string) => Buffer.from(str).toString('base64');

// test.use({ email: 'test@test.com', password: 'password' });
test.describe('Member Self-Management', () => {
	let testData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		testData = await createMember({ email: 'test@test.com' });
	});
	test.beforeEach(async ({ context }) => {
		const supabase = getSupabaseServiceClient();
		console.log('Supabase URL:', process.env.PUBLIC_SUPABASE_URL);

		const { data, error } = await supabase.auth.signInWithPassword({
			email: 'test@test.com',
			password: 'password'
		});

		if (error) throw error;
		if (!data.session) throw new Error('No session data returned');

		console.log('Sign-in successful, session:', data.session);

		// Extract project ref from SUPABASE_URL
		const projectRef = process.env.PUBLIC_SUPABASE_URL?.replace('http://', '').split('.').shift();
		if (!projectRef) throw new Error('Could not extract project ref from SUPABASE_URL');

		console.log('Project ref:', projectRef);
		console.log('Setting cookie with name:', `sb-${projectRef}-auth-token`);

		await context.addCookies([
			{
				name: `sb-${projectRef}-auth-token`,
				value: `base64-${btoa(JSON.stringify(data.session))}`,
				domain: '127.0.0.1',
				path: '/',
				httpOnly: false,
				secure: false,
				sameSite: 'Lax'
			}
		]);

		console.log('Cookie set successfully');
	});
	test.afterAll(() => testData?.cleanUp());

	test('should navigate to member profile', async ({ page }) => {
		await page.goto('/dashboard');
		await page.getByText(testData.email).click();
		await page.getByText('My profile').click();
		await expect(page.getByText(/member information/i)).toBeVisible();
	});

	test('should update member profile', async ({ page }) => {
		await page.goto('/dashboard');
		await page.getByText(testData.email).click();
		await page.getByText('My profile').click();
		await expect(page.getByText(/member information/i)).toBeVisible();
		await page.pause();
		await page.getByLabel(/first name/i).fill('Updated name');
		await page.getByRole('button', { name: /save changes/i }).click();

		await expect(page.getByText(/Your profile has been updated!/i)).toBeVisible();
		await page.reload();
		await expect(page.getByLabel(/first name/i)).toHaveValue('Updated name');
	});
});
