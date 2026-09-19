/** Browser-facing routes of the Invitation Acceptance flow. */
export const invitationPaths = {
	page: (invitationId: string) => `/members/signup/${invitationId}`,
	resume: (invitationId: string) => `/members/signup/${invitationId}/resume`,
	success: (invitationId: string) => `/members/signup/${invitationId}/success`,
	discord: (invitationId: string) => `/members/signup/${invitationId}/discord`,
} as const;
