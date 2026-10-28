import {
	authSessionSocketToken,
	authSessionShowSession,
	authSessionVerifyMagicLink,
	getClient,
	membersMe,
	notificationsList,
	onboardingVerifyInvitationAcceptance,
	beginnersWorkshopEmailTemplatesList,
	waitlistStatus,
} from "@dhc/api-client";
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

	it.each([
		["session probe", authSessionShowSession],
		["socket token", authSessionSocketToken],
		["own profile", membersMe],
		["notifications", notificationsList],
	] as const)(
		"does not report a signed-out %s as an exception",
		async (_name, read) => {
			fetchMock.mockResolvedValue(
				Response.json({ errors: { detail: "Unauthorized" } }, { status: 401 }),
			);
			const result = await read();
			expect(result.error).toEqual({ errors: { detail: "Unauthorized" } });
			expect(captureException).not.toHaveBeenCalled();
		},
	);

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

	it("does not report a request cancelled by its caller", async () => {
		const controller = new AbortController();
		fetchMock.mockImplementation(async () => {
			controller.abort();
			throw controller.signal.reason;
		});
		const result = await membersMe({ signal: controller.signal });
		expect(result.error).toHaveProperty("name", "AbortError");
		expect(captureException).not.toHaveBeenCalled();
	});

	it("still reports an AbortError when the request was not cancelled", async () => {
		fetchMock.mockRejectedValue(
			new DOMException("Unexpected abort", "AbortError"),
		);
		const result = await membersMe();
		expect(captureException).toHaveBeenCalledWith(
			result.error,
			expect.any(Object),
		);
	});

	it("does not report a socket-token timeout that the bridge retries", async () => {
		fetchMock.mockImplementation(() => new Promise(() => {}));
		const result = await authSessionSocketToken({ timeout: 1 });
		expect(result.error).toHaveProperty("name", "TimeoutError");
		expect(captureException).not.toHaveBeenCalled();
	});

	it("returns inactive-membership refusal without reporting an exception", async () => {
		fetchMock.mockResolvedValue(
			Response.json(
				{
					errors: {
						detail:
							"Your membership is inactive. Please contact the club to restore access.",
					},
				},
				{ status: 403 },
			),
		);
		const result = await authSessionVerifyMagicLink({
			body: { token: "test-token" },
		});
		expect(result.error).toBeDefined();
		expect(captureException).not.toHaveBeenCalled();
	});

	it("returns a valid invitation verification refusal without reporting an exception", async () => {
		fetchMock.mockResolvedValue(
			Response.json(
				{ data: { state: "restart_verification" } },
				{ status: 422 },
			),
		);
		const result = await onboardingVerifyInvitationAcceptance({
			body: {
				invitationId: "11111111-1111-4111-8111-111111111111",
				email: "invitee@example.test",
				dateOfBirth: "1990-01-01",
			},
		});
		expect(result.error).toEqual({ data: { state: "restart_verification" } });
		expect(captureException).not.toHaveBeenCalled();
	});

	it("still reports an invalid 200 email-template response", async () => {
		fetchMock.mockResolvedValue(
			Response.json({
				data: [
					{
						emailType: "follow_up",
						kind: "notice",
						buttonLabel: null,
						placeholders: ["firstName"],
						subject: "Thanks",
						body: { type: "doc", content: [] },
						updatedAt: "2026-10-28T10:00:00Z",
					},
				],
			}),
		);
		const result = await beginnersWorkshopEmailTemplatesList();
		expect(result.error).toHaveProperty("name", "ValiError");
		expect(result.error).toHaveProperty(
			"message",
			'Invalid key: Expected "label" but received undefined',
		);
		expect(captureException).toHaveBeenCalledWith(
			result.error,
			expect.any(Object),
		);
	});

	it.each([
		[401, { errors: { detail: "Unauthorized" } }],
		[403, { errors: { detail: "Insufficient role" } }],
		[422, { errors: { detail: "Invalid request" } }],
		[500, { errors: { detail: "Internal server error" } }],
	] as const)(
		"does not blanket-filter HTTP %i on other endpoints",
		async (status, body) => {
			fetchMock.mockResolvedValue(Response.json(body, { status }));
			const result = await waitlistStatus();
			expect(captureException).toHaveBeenCalledExactlyOnceWith(
				result.error,
				expect.any(Object),
			);
		},
	);

	it.each([
		[422, { data: { state: "unknown_state" } }],
		[422, { data: { state: "accepted" } }],
		[422, { errors: { detail: "Unexpected rejection" } }],
		[500, { data: { state: "restart_verification" } }],
	] as const)(
		"keeps unexpected verification responses visible (%i)",
		async (status, body) => {
			fetchMock.mockResolvedValue(Response.json(body, { status }));
			const result = await onboardingVerifyInvitationAcceptance({
				body: {
					invitationId: "11111111-1111-4111-8111-111111111111",
					email: "invitee@example.test",
					dateOfBirth: "1990-01-01",
				},
			});
			expect(captureException).toHaveBeenCalledExactlyOnceWith(
				result.error,
				expect.any(Object),
			);
		},
	);

	it("still reports timeouts for ordinary API reads", async () => {
		fetchMock.mockImplementation(() => new Promise(() => {}));
		const result = await waitlistStatus({ timeout: 1 });
		expect(result.error).toHaveProperty("name", "TimeoutError");
		expect(captureException).toHaveBeenCalledExactlyOnceWith(
			result.error,
			expect.any(Object),
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
