import { describe, expect, it, vi } from "vitest";
import { listWorkshopRefunds, submitWorkshopRefund } from "./workshop-refunds";

const { workshopsRefundRegistration, workshopsRefunds } = vi.hoisted(() => ({
	workshopsRefundRegistration: vi.fn(),
	workshopsRefunds: vi.fn(),
}));

vi.mock("@dhc/api-client", async (importOriginal) => ({
	...(await importOriginal<typeof import("@dhc/api-client")>()),
	workshopsRefundRegistration,
	workshopsRefunds,
}));

// ALE-164: the helpers now take a `Cookies` (SvelteKit request cookies) and
// forward the `_dhc_session` cookie to Phoenix, instead of the prior Supabase
// `access_token`. The fake cookies object below stands in for SvelteKit's
// `Cookies`.
function fakeCookies(sessionCookie: string | undefined): {
	get: (name: string) => string | undefined;
} {
	return {
		get: (name: string) =>
			name === "_dhc_session" ? sessionCookie : undefined,
	};
}

describe("Workshop refund API", () => {
	it("lists coordinator-visible refunds through the generated client with the session cookie", async () => {
		workshopsRefunds.mockResolvedValue({
			data: { data: { refunds: [{ id: "refund-1", status: "processing" }] } },
		});

		const result = await listWorkshopRefunds(
			fakeCookies("signed-session-cookie"),
			"workshop-1",
		);

		// ALE-164: the cookie is forwarded via the `cookie` header, not a bearer
		// `auth` field. The `_dhc_session` cookie value is the credential.
		expect(workshopsRefunds).toHaveBeenCalledWith({
			baseUrl: "http://localhost:4000/api",
			credentials: "include",
			headers: { cookie: "_dhc_session=signed-session-cookie" },
			path: { workshopId: "workshop-1" },
		});
		expect(result).toEqual([{ id: "refund-1", status: "processing" }]);
	});

	it("submits an explicit refund through the generated client with the session cookie", async () => {
		workshopsRefundRegistration.mockResolvedValue({
			data: { data: { refund: { id: "refund-1", status: "processing" } } },
		});

		const result = await submitWorkshopRefund(
			fakeCookies("signed-session-cookie"),
			{
				workshopId: "workshop-1",
				registrationId: "registration-1",
				reason: "Requested by attendee",
			},
		);

		expect(workshopsRefundRegistration).toHaveBeenCalledWith({
			baseUrl: "http://localhost:4000/api",
			credentials: "include",
			headers: { cookie: "_dhc_session=signed-session-cookie" },
			path: {
				workshopId: "workshop-1",
				registrationId: "registration-1",
			},
			body: { reason: "Requested by attendee" },
		});
		expect(result).toEqual({ id: "refund-1", status: "processing" });
	});

	it("omits the cookie header when there is no session cookie", async () => {
		workshopsRefunds.mockResolvedValue({
			data: { data: { refunds: [] } },
		});

		await listWorkshopRefunds(fakeCookies(undefined), "workshop-1");

		expect(workshopsRefunds).toHaveBeenCalledWith({
			baseUrl: "http://localhost:4000/api",
			credentials: "include",
			headers: {},
			path: { workshopId: "workshop-1" },
		});
	});
});
