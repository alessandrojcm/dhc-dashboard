import type { InvitationAcceptanceStatus } from "./vocabulary";

export type OnboardingStep = 1 | 2 | 3;

export type AcceptanceStepPresentation = {
	step: OnboardingStep;
	title: string;
	description: string;
};

/**
 * One intentional presentation per Phoenix status. The `Record` is exhaustive
 * on purpose: adding a status to the vocabulary without deciding how it renders
 * is a type error, not a fallthrough to step 1.
 */
export const acceptanceStepPresentation = {
	restartVerification: {
		step: 1,
		title: "Verify Your Invitation",
		description:
			"Confirm the email address and date of birth on your invitation.",
	},
	awaitingDiscord: {
		step: 2,
		title: "Connect Discord",
		description: "Link the Discord account you use for club communication.",
	},
	discordVerified: {
		step: 2,
		title: "Discord verified",
		description: "Check the account below before moving on to payment.",
	},
	discordCollision: {
		step: 2,
		title: "This Discord account cannot be used",
		description: "Your membership and payment have not been created.",
	},
	discordUnavailable: {
		step: 2,
		title: "Discord is temporarily unavailable",
		description: "Nothing has been charged. You can safely try again.",
	},
	paymentReady: {
		step: 3,
		title: "Finish your membership",
		description: "Add an emergency contact and choose your membership plan.",
	},
	paymentPending: {
		step: 3,
		title: "Payment in progress",
		description: "We are finishing your membership setup.",
	},
	paymentNeedsAction: {
		step: 3,
		title: "Payment needs attention",
		description: "Your progress is safe and your Discord account stays linked.",
	},
	paymentTerminal: {
		step: 3,
		title: "Payment could not be completed",
		description: "Your verified invitation is still saved.",
	},
	// The accepted state redirects to /success before rendering; this entry
	// exists so the record stays exhaustive and a direct render is still sane.
	accepted: {
		step: 3,
		title: "Membership created",
		description: "Sign in with your membership email to continue.",
	},
} satisfies Record<InvitationAcceptanceStatus, AcceptanceStepPresentation>;

export function presentAcceptanceStep(
	state: InvitationAcceptanceStatus,
): AcceptanceStepPresentation {
	return acceptanceStepPresentation[state];
}
