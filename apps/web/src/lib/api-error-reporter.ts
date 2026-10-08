import { getClient } from "@dhc/api-client";
import * as Sentry from "@sentry/sveltekit";

let apiErrorReporterRegistered = false;

export function registerApiErrorReporter(
	captureException = Sentry.captureException,
) {
	if (apiErrorReporterRegistered) {
		return;
	}

	getClient().interceptors.error.use((error, response, request, options) => {
		// The best-effort notification bridge retries token transport failures
		// with bounded backoff and logs their unavailability. They are not
		// application exceptions; retain reporting for HTTP and other failures.
		if (
			!response &&
			error instanceof Error &&
			error.name === "NetworkError" &&
			request?.method === "GET" &&
			new URL(request.url).pathname === "/api/auth/socket-token"
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
