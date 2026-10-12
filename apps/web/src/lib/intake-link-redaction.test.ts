import { describe, expect, it } from "vitest";
import {
	REDACTED,
	redactIntakeLinks,
	redactPayload,
	redactSentryEvent,
	redactSentrySpan,
} from "./intake-link-redaction";

const token = "q2FvZ0xk3W_example-token";

describe("redactIntakeLinks", () => {
	it("redacts the token of a page path, an API path and a full URL", () => {
		expect(redactIntakeLinks(`/beginners/intake/${token}`)).toBe(
			`/beginners/intake/${REDACTED}`,
		);
		expect(
			redactIntakeLinks(
				`https://api.example.com/api/beginners/intake/${token}/payment`,
			),
		).toBe(`https://api.example.com/api/beginners/intake/${REDACTED}/payment`);
		expect(
			redactIntakeLinks(
				`https://app.example.com/beginners/intake/${token}?session_id=cs_1`,
			),
		).toBe(
			`https://app.example.com/beginners/intake/${REDACTED}?session_id=cs_1`,
		);
	});

	it("leaves other paths alone", () => {
		expect(redactIntakeLinks("/dashboard/beginners-workshop")).toBe(
			"/dashboard/beginners-workshop",
		);
	});
});

describe("redactPayload", () => {
	it("redacts every string in a nested payload without mutating it", () => {
		const event = {
			request: { url: `https://app.example.com/beginners/intake/${token}` },
			breadcrumbs: [{ data: { from: "/", to: `/beginners/intake/${token}` } }],
			properties: { $current_url: `/beginners/intake/${token}`, count: 2 },
		};

		const redacted = redactPayload(event);

		expect(JSON.stringify(redacted)).not.toContain(token);
		expect(redacted?.properties.count).toBe(2);
		expect(event.request.url).toContain(token);
	});

	it("drops a payload it cannot serialise rather than leak it", () => {
		const cyclic = { url: `/beginners/intake/${token}`, self: {} };
		cyclic.self = cyclic;
		expect(redactPayload(cyclic)).toBeNull();
	});
});

describe("Sentry", () => {
	it("keeps sdkProcessingMetadata (live scopes) untouched and redacts the rest", () => {
		const scope = { url: `/beginners/intake/${token}`, self: {} };
		scope.self = scope;
		const event = {
			transaction: `GET /beginners/intake/${token}`,
			sdkProcessingMetadata: { scope },
		};

		const redacted = redactSentryEvent(event);

		expect(redacted?.transaction).toBe(`GET /beginners/intake/${REDACTED}`);
		expect(redacted?.sdkProcessingMetadata.scope).toBe(scope);
	});

	it("redacts a span's description and attributes", () => {
		const span = {
			description: `GET https://api.example.com/api/beginners/intake/${token}`,
			data: {
				"url.full": `https://api.example.com/api/beginners/intake/${token}`,
			},
		};
		expect(JSON.stringify(redactSentrySpan(span))).not.toContain(token);
	});
});
