import { error } from "@sveltejs/kit";
import dayjs from "dayjs";
import * as v from "valibot";
import { form, getRequestEvent } from "$app/server";
import { inviteValidationSchema } from "$lib/schemas/inviteValidationSchema";
import { memberSignupSchema } from "$lib/schemas/membersSignup";
import {
	applyInvitationRouteOutcome,
	applyRouteEffects,
	continueToPayment as continueToPaymentWorkflow,
	invitationAcceptanceDeps,
	restartDiscordVerification as restartDiscordVerificationWorkflow,
	submitInvitationPayment,
	verifyInvitationCredentials,
} from "$lib/server/invitation-acceptance";
import logger from "$lib/server/services/shared/logger";

/**
 * Remote commands of the Invitation Acceptance flow. Each one is a thin
 * adapter: collect request-local input, run the workflow operation, apply the
 * effects it requested, and answer with data or a redirect. Phoenix status
 * interpretation lives in `$lib/server/invitation-acceptance`, not here.
 */

function requireInvitationId(): string {
	const invitationId = getRequestEvent().params.invitationId;
	if (!invitationId) throw error(400, "Invitation ID is required");
	return invitationId;
}

/**
 * Validates an invitation by checking email and date of birth
 */
export const validateInvitation = form(inviteValidationSchema, async (data) => {
	const event = getRequestEvent();
	const invitationId = requireInvitationId();
	const deps = invitationAcceptanceDeps(event.cookies);

	const outcome = await verifyInvitationCredentials(deps, {
		invitationId,
		email: data.email,
		dateOfBirth: dayjs(data.dateOfBirth).format("YYYY-MM-DD"),
	});
	applyRouteEffects(outcome.effects, deps.cookies);

	if (outcome.type === "REJECTED") {
		logger.warn("[validateInvitation] Verification rejected", {
			invitationId,
			reason: outcome.reason,
		});
		return { success: false, verified: false };
	}

	return { success: true, verified: true };
});

export const restartDiscordVerification = form(v.object({}), async () => {
	const event = getRequestEvent();
	const invitationId = requireInvitationId();
	const deps = invitationAcceptanceDeps(event.cookies);

	applyInvitationRouteOutcome(await restartDiscordVerificationWorkflow(deps), {
		cookies: deps.cookies,
		invitationId,
		mode: "redirect",
	});
});

export const continueToPayment = form(async () => {
	const event = getRequestEvent();
	const invitationId = requireInvitationId();
	const deps = invitationAcceptanceDeps(event.cookies);

	applyInvitationRouteOutcome(await continueToPaymentWorkflow(deps), {
		cookies: deps.cookies,
		invitationId,
		mode: "redirect",
	});
});

/**
 * Processes payment for member signup. Success and still-pending answers
 * redirect (the page renders Phoenix's state); failures are returned so the
 * payment UI machine can show them and offer a retry.
 */
export const processPayment = form(memberSignupSchema, async (data) => {
	const event = getRequestEvent();
	const invitationId = requireInvitationId();
	const deps = invitationAcceptanceDeps(event.cookies);

	logger.debug(
		`[processPayment] Starting payment processing for invitation: ${invitationId}`,
	);

	const outcome = await submitInvitationPayment(deps, {
		nextOfKinName: data.nextOfKin,
		nextOfKinPhone: data.nextOfKinNumber,
		stripeConfirmationToken: data.stripeConfirmationToken || undefined,
		couponCode: data.couponCode || undefined,
		mandateContext: {
			ipAddress: event.getClientAddress(),
			userAgent: event.request.headers.get("user-agent") ?? undefined,
		},
	});

	if (outcome.type === "PAYMENT_FAILED") {
		applyRouteEffects(outcome.effects, deps.cookies);
		logger.error("[processPayment] Payment processing failed", {
			invitationId,
			recoverable: outcome.recoverable,
			returnedMessage: outcome.message,
		});
		return {
			paymentFailed: true as const,
			recoverable: outcome.recoverable,
			error: outcome.message,
		};
	}

	applyInvitationRouteOutcome(outcome, {
		cookies: deps.cookies,
		invitationId,
		mode: "redirect",
	});
});
