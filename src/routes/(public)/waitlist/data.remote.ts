import { form, getRequestEvent } from '$app/server';
import { invalid } from '@sveltejs/kit';
import * as v from 'valibot';
import beginnersWaitlist, { beginnersWaitlistClientSchema } from '$lib/schemas/beginnersWaitlist';
import { createWaitlistService } from '$lib/server/services/members';

/**
 * Waitlist submission form
 * Uses the simplified client schema for type inference, but validates with the full
 * complex schema on the server to ensure all cross-field validation and transformations are applied.
 */
export const submitWaitlist = form(beginnersWaitlistClientSchema, async (data, issue) => {
	const event = getRequestEvent();

	// Transform client data (string dateOfBirth) to server types (Date) for complex schema validation
	const transformedData = {
		...data,
		dateOfBirth: new Date(data.dateOfBirth)
	};

	// Validate with the full complex schema (includes cross-field validation and transformations)
	const result = v.safeParse(beginnersWaitlist, transformedData);

	if (!result.success) {
		// Map Valibot validation errors to form field issues
		for (const validationIssue of result.issues) {
			const fieldPath = validationIssue.path?.map((p) => p.key).join('.') || '';
			if (fieldPath) {
				// Create field-specific issue using dynamic property access
				// eslint-disable-next-line @typescript-eslint/no-explicit-any
				const issueProxy = issue as any;
				if (typeof issueProxy[fieldPath] === 'function') {
					invalid(issueProxy[fieldPath](validationIssue.message));
				}
			} else {
				// Form-level error
				invalid(validationIssue.message);
			}
		}
		return;
	}

	try {
		const waitlistService = createWaitlistService(event.platform!);
		await waitlistService.create(result.output);
	} catch (err) {
		console.error('Waitlist submission error:', err);

		if (err instanceof Error && err.message.includes('duplicate')) {
			invalid(issue.email('This email is already on the waitlist'));
		}

		throw new Error('Something went wrong, please try again later.');
	}

	return { success: 'You have been added to the waitlist, we will be in contact soon!' };
});
