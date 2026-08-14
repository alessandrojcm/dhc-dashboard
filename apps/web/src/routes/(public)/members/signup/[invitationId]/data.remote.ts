import {
	invitationsAccept,
	onboardingContinueAcceptance,
	onboardingVerifyInvitationAcceptance,
} from "@dhc/api-client";
import { error, isRedirect, redirect } from "@sveltejs/kit";
import dayjs from "dayjs";
import { form, getRequestEvent } from "$app/server";
import { inviteValidationSchema } from "$lib/schemas/inviteValidationSchema";
import { memberSignupSchema } from "$lib/schemas/membersSignup";
import { apiBaseUrl } from "$lib/server/api-client";
import {
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

/**
 * Processes payment for member signup
 */
export const processPayment = form(memberSignupSchema, async (data) => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	logger.debug(
		`[processPayment] Starting payment processing for invitation: ${invitationId}`,
	);
	logger.debug("[processPayment] Received data:", {
		nextOfKin: data.nextOfKin,
		nextOfKinNumber: data.nextOfKinNumber,
		stripeConfirmationToken: data.stripeConfirmationToken
			? `${data.stripeConfirmationToken.substring(0, 10)}...`
			: "MISSING",
		couponCode: data.couponCode || "none",
	});

	if (!invitationId) {
		throw error(400, "Invitation ID is required");
	}

	let acceptanceError: unknown;
	let acceptanceStatus: number | undefined;

	try {
		const protectedContinuation = event.cookies.get(
			`onboarding-acceptance-${invitationId}`,
		);

		if (protectedContinuation) {
			const acceptance = await onboardingContinueAcceptance({
				baseUrl: apiBaseUrl(),
				headers: { "x-onboarding-continuation": protectedContinuation },
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

			if (acceptance.error || acceptance.data?.data.state !== "accepted") {
				acceptanceError = acceptance.error;
				acceptanceStatus = acceptance.response?.status;
				throw error(
					acceptanceStatus ?? 500,
					acceptanceStatus === 402
						? "Payment could not be completed"
						: "Invitation acceptance failed",
				);
			}

			event.cookies.delete(`onboarding-acceptance-${invitationId}`, {
				path: "/",
			});
			throw redirect(303, `/members/signup/${invitationId}/success`);
		}

		const verificationToken = event.cookies.get(
			`invite-verification-${invitationId}`,
		);

		if (!verificationToken) {
			throw error(
				400,
				"Invitation verification has expired. Please verify again.",
			);
		}

		const acceptance = await invitationsAccept({
			baseUrl: apiBaseUrl(),
			path: { id: invitationId },
			timeout: invitationAcceptanceTimeout,
			body: {
				verificationToken,
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

		if (acceptance.error || !acceptance.data?.data.accepted) {
			acceptanceError = acceptance.error;
			acceptanceStatus = acceptance.response?.status;
			const status = acceptanceStatus ?? 500;
			const message =
				status === 402
					? "Payment could not be completed"
					: "Invitation acceptance failed";

			throw error(status, message);
		}

		// Success! Delete temporary invitation cookies.
		logger.debug("[processPayment] Payment processing completed successfully");
		event.cookies.delete("access-token", { path: "/" });
		event.cookies.delete(`invite-verification-${invitationId}`, { path: "/" });
		event.cookies.delete(`invite-confirmed-${invitationId}`, { path: "/" });
		throw redirect(301, `/members/signup/${invitationId}/success`);
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
