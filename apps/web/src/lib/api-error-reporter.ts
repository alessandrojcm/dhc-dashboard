import { getClient } from "@dhc/api-client";
import * as Sentry from "@sentry/sveltekit";
import { apiProblem } from "#lib/api-error.js";
import { acceptanceVerificationRefusalSchema } from "#lib/invitation-acceptance/vocabulary.js";
import * as v from "valibot";

let apiErrorReporterRegistered = false;

export function registerApiErrorReporter(
	captureException = Sentry.captureException,
) {
	if (apiErrorReporterRegistered) {
		return;
	}

	getClient().interceptors.error.use((error, response, request, options) => {
		const path = request ? new URL(request.url).pathname : undefined;
		// Only a caller-aborted request is cancellation, not any exception
		// named AbortError (nor a timeout created by the transport).
		if (
			(request?.signal.aborted ||
				options.signal?.aborted ||
				options.kyOptions?.signal?.aborted) &&
			error instanceof Error &&
			error.name === "AbortError"
		) {
			return error;
		}
		// These background/session reads legitimately encounter a signed-out
		// browser. Keep unexpected bodies, other endpoints and server failures.
		if (
			request?.method === "GET" &&
			response?.status === 401 &&
			path &&
			[
				"/api/auth/session",
				"/api/auth/socket-token",
				"/api/members/me",
				"/api/notifications",
			].includes(path) &&
			apiProblem(error)?.detail === "Unauthorized"
		) {
			return error;
		}
		if (
			request?.method === "POST" &&
			path === "/api/auth/magic-link/verify" &&
			response?.status === 403 &&
			apiProblem(error)?.detail ===
				"Your membership is inactive. Please contact the club to restore access."
		) {
			return error;
		}
		// The Acceptance vocabulary validates a closed safe view. This does
		// not interpret its state or hide malformed/unexpected responses.
		if (
			request?.method === "POST" &&
			path === "/api/onboarding/invitation-acceptance/verify" &&
			response?.status === 422 &&
			v.is(acceptanceVerificationRefusalSchema, error)
		) {
			return error;
		}
		// The best-effort notification bridge retries token transport failures
		// with bounded backoff and logs their unavailability. They are not
		// application exceptions; retain reporting for HTTP and other failures.
		if (
			!response &&
			error instanceof Error &&
			(error.name === "NetworkError" || error.name === "TimeoutError") &&
			request?.method === "GET" &&
			path === "/api/auth/socket-token"
		) {
			return error;
		}

		captureException(error, {
			tags: {
				api_client: "hey-api",
				api_error_name:
					error instanceof Error ? error.name : "NonErrorApiFailure",
			},
			contexts: {
				api: {
					method: request?.method ?? options.method,
					url: request?.url ?? options.url,
					status: response?.status,
					statusText: response?.statusText,
				},
			},
		});

		return error;
	});

	apiErrorReporterRegistered = true;
}
