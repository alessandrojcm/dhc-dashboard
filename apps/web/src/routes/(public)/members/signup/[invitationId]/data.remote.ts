import {
	onboardingCancelDiscord,
	onboardingContinueAcceptance,
	onboardingSubmitPayment,
	onboardingVerifyInvitationAcceptance,
} from "@dhc/api-client";
import { error, isRedirect, redirect } from "@sveltejs/kit";
import dayjs from "dayjs";
import * as v from "valibot";
import { form, getRequestEvent } from "$app/server";
import { inviteValidationSchema } from "$lib/schemas/inviteValidationSchema";
import { memberSignupSchema } from "$lib/schemas/membersSignup";
import {
	clearInvitationAcceptanceProof,
	hasInvitationAcceptanceProof,
	invitationAcceptanceApiOptions,
	relayInvitationAcceptanceProof,
} from "$lib/server/invitation-acceptance-proof";
import { completeInvitationAcceptance } from "$lib/server/post-acceptance-sign-in-handoff";
import logger from "$lib/server/services/shared/logger";
import { apiErrorDetail } from "$lib/server/api-error";

const invitationAcceptanceTimeout = 60_000;
const PaymentErrorMetadataSchema = v.object({
	code: v.optional(v.string()),
	type: v.optional(v.string()),
});

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
		...invitationAcceptanceApiOptions(event.cookies),
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
		if (
			protectedState?.state === "restart_verification" ||
			rawResponse?.status === 409
		) {
			clearInvitationAcceptanceProof(event.cookies);
		}
		logger.warn("[validateInvitation] Verification response rejected", {
			invitationId,
			status: rawResponse?.status,
			state: protectedState?.state,
			hasApiError: Boolean(response.error),
			hasResponse: Boolean(rawResponse),
		});
		return { success: false, verified: false };
	}

	const cookieRelayed = relayInvitationAcceptanceProof(
		event.cookies,
		rawResponse.headers,
	);

	if (!cookieRelayed) {
		logger.warn("[validateInvitation] Acceptance cookie was not relayed", {
			invitationId,
			status: rawResponse.status,
			hasSetCookieHeader: rawResponse.headers.has("set-cookie"),
		});
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

	try {
		if (hasInvitationAcceptanceProof(event.cookies)) {
			await onboardingCancelDiscord({
				...invitationAcceptanceApiOptions(event.cookies),
			});
		}
	} finally {
		clearInvitationAcceptanceProof(event.cookies);
	}
	redirect(303, `/members/signup/${invitationId}`);
});

export const continueToPayment = form(async () => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	if (!invitationId) throw error(400, "Invitation ID is required");

	const response = await onboardingContinueAcceptance({
		...invitationAcceptanceApiOptions(event.cookies),
	});

	if (response.error || response.data?.data.state !== "paymentReady") {
		if (response.data?.data.state === "restart_verification") {
			clearInvitationAcceptanceProof(event.cookies);
		}
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

	let acceptanceErrorDetail: string | undefined;
	let acceptanceStatus: number | undefined;

	try {
		if (!hasInvitationAcceptanceProof(event.cookies)) {
			throw error(
				409,
				"Invitation verification has expired. Please verify again.",
			);
		}

		const acceptance = await onboardingSubmitPayment({
			...invitationAcceptanceApiOptions(event.cookies),
			timeout: invitationAcceptanceTimeout,
			body: {
				nextOfKinName: data.nextOfKin,
				nextOfKinPhone: data.nextOfKinNumber,
				stripeConfirmationToken: data.stripeConfirmationToken || undefined,
				couponCode: data.couponCode || undefined,
				mandateContext: {
					ipAddress: event.getClientAddress(),
					userAgent: event.request.headers.get("user-agent") ?? undefined,
				},
			},
		});

		const state = acceptance.data?.data.state;
		if (state === "restart_verification") {
			clearInvitationAcceptanceProof(event.cookies);
		}
		if (acceptance.error) {
			acceptanceErrorDetail = apiErrorDetail(acceptance.error);
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

		completeInvitationAcceptance(
			event.cookies,
			acceptance.data?.data.invitationEmail,
			invitationId,
		);
	} catch (err) {
		if (isRedirect(err)) {
			throw err;
		}
		const paymentErrorMetadata = v.safeParse(PaymentErrorMetadataSchema, err);
		const errorCode = paymentErrorMetadata.success
			? paymentErrorMetadata.output.code
			: undefined;
		const errorType = paymentErrorMetadata.success
			? paymentErrorMetadata.output.type
			: undefined;

		const errorDetails = {
			invitationId,
			name: err instanceof Error ? err.name : "unknown",
			message: err instanceof Error ? err.message : String(err),
			status: acceptanceStatus,
			apiError: acceptanceErrorDetail,
			code: errorCode ?? "none",
			type: errorType ?? "none",
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

		if (errorCode) {
			switch (errorCode) {
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
					errorMessage = `An error occurred with the payment processor (${errorCode})`;
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
