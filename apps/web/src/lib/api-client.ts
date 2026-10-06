import { configureClient, getClient } from "@dhc/api-client";
import { PUBLIC_API_BASE_URL } from "$app/env/public";
import { registerApiErrorReporter } from "#lib/api-error-reporter.js";

const DEFAULT_API_BASE_URL = "/api";

export function publicApiBaseUrl(): string {
	return PUBLIC_API_BASE_URL || DEFAULT_API_BASE_URL;
}

export function configureBrowserApiClient(): void {
	configureClient({
		baseUrl: publicApiBaseUrl(),
		credentials: "include",
		retry: 0,
	});

	registerApiErrorReporter();
}

/** Build a browser-facing API URL through the configured Hey API client. */
export function publicApiUrl(path: string): string {
	return getClient().buildUrl({
		baseUrl: publicApiBaseUrl(),
		url: path,
	});
}
