import { describe, expect, it } from "vitest";
import {
	apiClientOptions,
	type ClientForwarding,
} from "#lib/server/api-client.js";

const cookies = {
	get: (name: string) =>
		name === "_dhc_session" ? "session-value" : undefined,
};

function forwarding(
	secret: string | undefined,
	clientAddress: string | undefined,
): ClientForwarding {
	return { secret, clientAddress: () => clientAddress };
}

describe("apiClientOptions client-address forwarding", () => {
	it("forwards the browser's address and the shared secret on server-side calls", () => {
		expect(
			apiClientOptions(cookies, forwarding("forwarding-secret", "203.0.113.7"))
				.headers,
		).toEqual({
			cookie: "_dhc_session=session-value",
			"x-dhc-client-ip": "203.0.113.7",
			"x-dhc-forwarding-secret": "forwarding-secret",
		});
	});

	it("sends no forwarding headers when the secret is unset", () => {
		expect(
			apiClientOptions(cookies, forwarding(undefined, "203.0.113.7")).headers,
		).toEqual({ cookie: "_dhc_session=session-value" });
	});

	it("sends no forwarding headers outside a request", () => {
		expect(
			apiClientOptions(cookies, forwarding("forwarding-secret", undefined))
				.headers,
		).toEqual({ cookie: "_dhc_session=session-value" });
	});

	it("reads no request outside a request context by default", () => {
		expect(apiClientOptions(cookies).headers).toEqual({
			cookie: "_dhc_session=session-value",
		});
	});
});
