import {
	onboardingCancelDiscord,
	onboardingContinueAcceptance,
	onboardingRetryAcceptance,
	onboardingShowInvitationAcceptance,
	onboardingSubmitPayment,
	onboardingVerifyInvitationAcceptance,
} from "@dhc/api-client";
import { apiErrorDetail } from "$lib/api-error";
import * as v from "valibot";
import {
	acceptanceStateResponseSchema,
	type AcceptanceApiResult,
	type AcceptanceView,
} from "$lib/invitation-acceptance/vocabulary";
import { apiBaseUrl } from "$lib/server/api-client";
import { acceptanceProofCookie, issuedProofFrom } from "./cookie-store";
import type { AcceptanceProof, InvitationAcceptanceApi } from "./ports";

/**
 * Production adapter: the generated `@dhc/api-client` operations behind the
 * `InvitationAcceptanceApi` port. Transport concerns (proof header, timeouts,
 * ky error shapes, body parsing) end here.
 */

const paymentTimeoutMs = 60_000;

/**
 * Request options that attach the opaque handle to one trusted Phoenix call.
 * Also used by the Discord OAuth start endpoint and the pricing query, which
 * are transport-only and need no workflow decision.
 */
export function invitationAcceptanceRequestOptions(
	proof: AcceptanceProof | undefined,
) {
	return {
		baseUrl: apiBaseUrl(),
		credentials: "include" as const,
		headers: proof
			? { cookie: `${acceptanceProofCookie}=${proof}` }
			: undefined,
	};
}

/**
 * What the generated client hands back: the parsed body under `data` on 2xx
 * or `error` otherwise, and the raw `Response` when the request reached Phoenix.
 * Both bodies are untrusted until parsed here.
 */
type ClientResponse = {
	data?: unknown;
	error?: unknown;
	response?: Response;
};

function viewFrom(body: ClientResponse["data"]): AcceptanceView | undefined {
	const parsed = v.safeParse(acceptanceStateResponseSchema, body);
	return parsed.success ? parsed.output.data : undefined;
}

export function interpretAcceptanceResponse(
	response: ClientResponse,
): AcceptanceApiResult {
	const httpStatus = response.response?.status;

	const view = viewFrom(response.data) ?? viewFrom(response.error);
	if (view && httpStatus !== undefined) {
		return { kind: "view", httpStatus, view };
	}

	if (httpStatus !== undefined) {
		return {
			kind: "rejected",
			httpStatus,
			detail: apiErrorDetail(response.error),
		};
	}

	const error = response.error;
	const isTimeout = error instanceof Error && error.name === "TimeoutError";
	return {
		kind: "unavailable",
		reason: isTimeout ? "timeout" : "network",
		detail: error instanceof Error ? error.message : undefined,
	};
}

async function guarded(
	call: () => Promise<ClientResponse>,
): Promise<AcceptanceApiResult> {
	try {
		return interpretAcceptanceResponse(await call());
	} catch (error) {
		return interpretAcceptanceResponse({ error });
	}
}

export function apiClientAcceptanceApi(): InvitationAcceptanceApi {
	return {
		async verify(proof, credentials) {
			try {
				const response = await onboardingVerifyInvitationAcceptance({
					...invitationAcceptanceRequestOptions(proof),
					body: credentials,
				});
				return {
					result: interpretAcceptanceResponse(response),
					issuedProof: response.response
						? issuedProofFrom(response.response.headers)
						: undefined,
				};
			} catch (error) {
				return {
					result: interpretAcceptanceResponse({ error }),
					issuedProof: undefined,
				};
			}
		},
		show: (proof) =>
			guarded(() =>
				onboardingShowInvitationAcceptance(
					invitationAcceptanceRequestOptions(proof),
				),
			),
		continueAcceptance: (proof) =>
			guarded(() =>
				onboardingContinueAcceptance(invitationAcceptanceRequestOptions(proof)),
			),
		submitPayment: (proof, payment) =>
			guarded(() =>
				onboardingSubmitPayment({
					...invitationAcceptanceRequestOptions(proof),
					timeout: paymentTimeoutMs,
					body: payment,
				}),
			),
		retry: (proof) =>
			guarded(() =>
				onboardingRetryAcceptance(invitationAcceptanceRequestOptions(proof)),
			),
		cancelDiscord: (proof) =>
			guarded(() =>
				onboardingCancelDiscord(invitationAcceptanceRequestOptions(proof)),
			),
	};
}
