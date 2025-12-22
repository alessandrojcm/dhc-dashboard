import { form, getRequestEvent } from '$app/server';
import { inviteValidationSchema } from '$lib/schemas/inviteValidationSchema';

/**
 * Validates an invitation by checking email and date of birth
 */
export const validateInvitation = form(inviteValidationSchema, async (data) => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	if (!invitationId) {
		throw new Error('Invitation ID is required');
	}

	// Call the API endpoint to validate the invitation
	const response = await fetch(`${event.url.origin}/api/invite/${invitationId}`, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json'
		},
		body: JSON.stringify({
			email: data.email,
			dateOfBirth: data.dateOfBirth
		})
	});

	if (!response.ok) {
		throw new Error('Invalid invitation details. Please check your email and date of birth.');
	}

	return { success: true, verified: true };
});
