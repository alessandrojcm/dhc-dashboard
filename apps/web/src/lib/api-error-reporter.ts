import { getClient } from "@dhc/api-client";
import * as Sentry from "@sentry/sveltekit";

let apiErrorReporterRegistered = false;

export function registerApiErrorReporter() {
	if (apiErrorReporterRegistered) {
		return;
	}

	getClient().interceptors.error.use((error, response, request, options) => {
		Sentry.captureException(error, {
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
