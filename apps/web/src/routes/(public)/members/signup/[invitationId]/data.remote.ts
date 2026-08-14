import {
	onboardingCancelDiscord,
	onboardingContinueAcceptance,
	onboardingSubmitPayment,
	onboardingVerifyInvitationAcceptance,
} from "@dhc/api-client";
import { dev } from "$app/environment";
import { error, isRedirect, redirect } from "@sveltejs/kit";
import dayjs from "dayjs";
import * as v from "valibot";
import { form, getRequestEvent } from "$app/server";
import { inviteValidationSchema } from "$lib/schemas/inviteValidationSchema";
import { memberSignupSchema } from "$lib/schemas/membersSignup";
import {
	onboardingAcceptanceCookie,
	onboardingApiClientOptions,
	relayOnboardingAcceptanceCookie,
} from "$lib/server/onboarding-api";
import logger from "$lib/server/services/shared/logger";

const invitationAcceptanceTimeout = 60_000;

/**
 * Validates an invitation by checking email and date of birth
 */
export const validateInvitation = form(inviteValidationSchema, async (data) => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	if (!invitationId) {
		throw new Error("Invitation ID is required");
	}
	const response = await onboardingVerifyInvitationAcceptance({
		...onboardingApiClientOptions(event.cookies),
		body: {
			invitationId,
			email: data.email,
			dateOfBirth: dayjs(data.dateOfBirth).format("YYYY-MM-DD"),
		},
	});

	const protectedState = response.data?.data;
	const rawResponse = response.response;
	if (
		response.error ||
		protectedState?.state !== "awaiting_oauth" ||
		!rawResponse
	) {
		return { success: false, verified: false };
	}

	if (
		!relayOnboardingAcceptanceCookie(
			event.cookies,
			rawResponse.headers,
			invitationId,
		)
	) {
		return { success: false, verified: false };
	}

	return { success: true, verified: true };
});

export const restartDiscordVerification = form(v.object({}), async () => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	if (!invitationId) {
		throw error(400, "Invitation ID is required");
	}

	const protectedContinuation = event.cookies.get(onboardingAcceptanceCookie);

	if (protectedContinuation) {
		await onboardingCancelDiscord({
			...onboardingApiClientOptions(event.cookies),
		});
	}

	event.cookies.delete(onboardingAcceptanceCookie, {
		path: `/members/signup/${invitationId}`,
	});
	redirect(303, `/members/signup/${invitationId}`);
});

export const continueToPayment = form(async () => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	if (!invitationId) throw error(400, "Invitation ID is required");

	const response = await onboardingContinueAcceptance({
		...onboardingApiClientOptions(event.cookies),
	});

	if (response.error || response.data?.data.state !== "paymentReady") {
		throw error(
			response.response?.status ?? 409,
			"Unable to continue to payment",
		);
	}

	redirect(303, `/members/signup/${invitationId}`);
});

/**
 * Processes payment for member signup
 */
export const processPayment = form(memberSignupSchema, async (data) => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	logger.debug(
		`[processPayment] Starting payment processing for invitation: ${invitationId}`,
	);
	if (!invitationId) {
		throw error(400, "Invitation ID is required");
	}

	let acceptanceError: unknown;
	let acceptanceStatus: number | undefined;

	try {
		const protectedContinuation = event.cookies.get(onboardingAcceptanceCookie);

		if (!protectedContinuation) {
			throw error(
				409,
				"Invitation verification has expired. Please verify again.",
			);
		}

		const acceptance = await onboardingSubmitPayment({
			...onboardingApiClientOptions(event.cookies),
			timeout: invitationAcceptanceTimeout,
			body: {
				nextOfKinName: data.nextOfKin,
				nextOfKinPhone: data.nextOfKinNumber,
				stripeConfirmationToken: data.stripeConfirmationToken,
				couponCode: data.couponCode || undefined,
				mandateContext: {
					ipAddress: event.getClientAddress(),
					userAgent: event.request.headers.get("user-agent") ?? undefined,
				},
			},
		});

		const state = acceptance.data?.data.state;
		if (acceptance.error) {
			acceptanceError = acceptance.error;
			acceptanceStatus = acceptance.response?.status;
			throw error(
				acceptanceStatus ?? 500,
				acceptanceStatus === 402
					? "Payment could not be completed"
					: "Invitation acceptance failed",
			);
		}

		if (
			state === "paymentPending" ||
			state === "paymentNeedsAction" ||
			state === "paymentTerminal"
		) {
			throw redirect(303, `/members/signup/${invitationId}`);
		}

		if (state !== "accepted") {
			throw error(409, "Invitation acceptance failed");
		}

		if (acceptance.data?.data.invitationEmail) {
			event.cookies.set(
				"invitation-sign-in-prefill",
				acceptance.data.data.invitationEmail,
				{
					path: "/auth",
					httpOnly: true,
					secure: !dev,
					sameSite: "lax",
					maxAge: 10 * 60,
				},
			);
		}

		event.cookies.delete(onboardingAcceptanceCookie, {
			path: `/members/signup/${invitationId}`,
		});
		throw redirect(303, `/members/signup/${invitationId}/success`);
	} catch (err) {
		if (isRedirect(err)) {
			throw err;
		}

		const errorDetails = {
			invitationId,
			name: err instanceof Error ? err.name : "unknown",
			message: err instanceof Error ? err.message : String(err),
			status: acceptanceStatus,
			apiError: acceptanceError,
			code:
				err instanceof Error && "code" in err
					? (err as { code: string }).code
					: "none",
			type:
				err instanceof Error && "type" in err
					? (err as { type: string }).type
					: "none",
		};

		let errorMessage =
			acceptanceStatus === 402
				? "Payment could not be completed"
				: err instanceof Error
					? err.message
					: "An unexpected error occurred";

		if (err instanceof Error && err.name === "TimeoutError") {
			errorMessage =
				"Invitation acceptance is taking longer than expected. Please wait a moment and try again.";
		}

		if (err instanceof Error && "code" in err) {
			const stripeError = err as { code: string };
			switch (stripeError.code) {
				case "charge_exceeds_source_limit":
				case "charge_exceeds_transaction_limit":
					errorMessage =
						"The payment amount exceeds the account payment volume limit";
					break;
				case "charge_exceeds_weekly_limit":
					errorMessage =
						"The payment amount exceeds the weekly transaction limit";
					break;
				case "payment_intent_authentication_failure":
					errorMessage = "The payment authentication failed";
					break;
				case "payment_method_unactivated":
					errorMessage = "The payment method is not activated";
					break;
				case "payment_intent_payment_attempt_failed":
					errorMessage = "The payment attempt failed";
					break;
				default:
					errorMessage = `An error occurred with the payment processor (${stripeError.code})`;
					break;
			}
		}

		logger.error("[processPayment] Payment processing failed", {
			...errorDetails,
			returnedMessage: errorMessage,
		});
		return { paymentFailed: true, error: errorMessage };
	}
});
