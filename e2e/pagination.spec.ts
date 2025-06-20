import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Pagination tests', () => {
    let member: Awaited<ReturnType<typeof createMember>>;

    test.beforeAll(async () => {
        member = await createMember({ email: 'test.pagination@test.com' });
    });

    test.afterAll(async () => {
        await member.cleanUp();
    });

    test('should correctly paginate the members table', async ({ page, context }) => {
        await loginAsUser(context, member.email);

        await page.goto('/dashboard/members');

        await expect(page.locator('table tbody tr')).toHaveCount(10);

        // Get the text of the first row
        const firstRowText = await page.locator('table tbody tr:first-child').textContent();

        // Go to the next page
        await page.getByRole('button', { name: 'Next' }).click();
        await page.waitForLoadState('networkidle');

        await expect(page.locator('table tbody tr')).toHaveCount(10);
        
        // Get the text of the first row on the new page
        const newFirstRowText = await page.locator('table tbody tr:first-child').textContent();
        expect(firstRowText).not.toEqual(newFirstRowText);

        // Go to the last page
        await page.getByRole('button', { name: 'Last' }).click();
        await page.waitForLoadState('networkidle');

        const lastPageRows = await page.locator('table tbody tr').count();
        expect(lastPageRows).toBeGreaterThan(0);
        expect(lastPageRows).toBeLessThanOrEqual(10);
    });

    test('should correctly paginate the waitlist table', async ({ page, context }) => {
        await loginAsUser(context, member.email);

        await page.goto('/dashboard/beginners-workshop');
        
        await expect(page.locator('table tbody tr')).toHaveCount(10);

        // Get the text of the first row
        const firstRowText = await page.locator('table tbody tr:first-child').textContent();

        // Go to the next page
        await page.getByRole('button', { name: 'Next' }).click();
        await page.waitForLoadState('networkidle');

        await expect(page.locator('table tbody tr')).toHaveCount(10);
        
        // Get the text of the first row on the new page
        const newFirstRowText = await page.locator('table tbody tr:first-child').textContent();
        expect(firstRowText).not.toEqual(newFirstRowText);

        // Go to the last page
        await page.getByRole('button', { name: 'Last' }).click();
        await page.waitForLoadState('networkidle');

        const lastPageRows = await page.locator('table tbody tr').count();
        expect(lastPageRows).toBeGreaterThan(0);
        expect(lastPageRows).toBeLessThanOrEqual(10);
    });
}); 