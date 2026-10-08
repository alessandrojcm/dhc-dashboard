import { authSessionSocketToken, getClient, membersMe } from "@dhc/api-client";
import * as Sentry from "@sentry/sveltekit";
import {
	afterAll,
	beforeAll,
	beforeEach,
	describe,
	expect,
	it,
	vi,
} from "vitest";
import { registerApiErrorReporter } from "#lib/api-error-reporter.js";

describe("API error reporting", () => {
	const fetchMock = vi.fn<typeof fetch>();
	const captureException = vi.fn<typeof Sentry.captureException>();
	const originalConfig = getClient().getConfig();

	beforeAll(() => {
		getClient().setConfig({
			baseUrl: "https://api.example.test/api",
			retry: 0,
			kyOptions: { fetch: fetchMock },
		});
		registerApiErrorReporter(captureException);
	});

	afterAll(() => getClient().setConfig(originalConfig));
	beforeEach(() => vi.clearAllMocks());

	it("returns a socket-token network failure without capturing a Sentry exception", async () => {
		fetchMock.mockRejectedValue(new TypeError("Failed to fetch"));

		const result = await authSessionSocketToken();

		expect(result.error).toBeInstanceOf(Error);
		expect(result.error).toHaveProperty("name", "NetworkError");
		expect(result.data).toBeUndefined();
		expect(captureException).not.toHaveBeenCalled();
	});

	it("still reports network failures for ordinary API reads", async () => {
		fetchMock.mockRejectedValue(new TypeError("Failed to fetch"));

		const result = await membersMe();

		expect(captureException).toHaveBeenCalledWith(
			result.error,
			expect.objectContaining({
				tags: expect.objectContaining({ api_error_name: "NetworkError" }),
			}),
		);
	});

	it("still reports unexpected socket-token errors", async () => {
		const error = new Error("Unexpected request interceptor failure");
		const id = getClient().interceptors.request.use(() => {
			throw error;
		});
		try {
			const result = await authSessionSocketToken();
			expect(result.error).toBe(error);
			expect(captureException).toHaveBeenCalledWith(error, expect.any(Object));
		} finally {
			getClient().interceptors.request.eject(id);
		}
	});

	it.each([401, 500])(
		"still reports socket-token HTTP %i failures",
		async (status) => {
			fetchMock.mockResolvedValue(
				new Response(JSON.stringify({ detail: "Failure" }), {
					status,
					headers: { "content-type": "application/json" },
				}),
			);

			const result = await authSessionSocketToken();

			expect(captureException).toHaveBeenCalledWith(
				result.error,
				expect.objectContaining({
					contexts: { api: expect.objectContaining({ status }) },
				}),
			);
		},
	);
});
