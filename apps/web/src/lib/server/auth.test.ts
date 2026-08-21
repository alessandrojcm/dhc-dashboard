import { afterEach, describe, expect, it, vi } from "vitest";
import { getPhoenixSession, type PhoenixSessionClient } from "$lib/server/auth";

const authShowSession = vi.fn<PhoenixSessionClient["showSession"]>();
const client: PhoenixSessionClient = { showSession: authShowSession };

/**
 * ALE-164: focused integration tests for the SSR auth seam.
 *
 * `getPhoenixSession` is the server-side counterpart to the browser's
 * credentialed call to `GET /api/auth/session`: it reads the `_dhc_session`
 * cookie from the SvelteKit request and forwards it to Phoenix. These tests
 * verify the observable contract:
 *
 *   1. a valid session projection is returned when Phoenix reports 200;
 *   2. `null` when there is no `_dhc_session` cookie (no Phoenix call made);
 *   3. `null` when Phoenix returns 401 (invalid/expired/inactive session);
 *   4. `null` when the call throws (network/decode failure) — never throws;
 *   5. the cookie is forwarded via the `cookie` header, not a bearer.
 */
function fakeCookies(sessionCookie: string | undefined) {
	return {
		get: (name: string) =>
			name === "_dhc_session" ? sessionCookie : undefined,
	};
}

afterEach(() => {
	authShowSession.mockReset();
});

describe("getPhoenixSession (SSR auth seam, ALE-164)", () => {
	it("returns the session projection when Phoenix reports a valid active session", async () => {
		authShowSession.mockResolvedValue({
			data: {
				data: {
					principal: {
						id: "11111111-1111-1111-1111-111111111111",
						email: "u@example.com",
					},
					roles: ["member", "admin"],
				},
			},
			error: undefined,
		});

		const session = await getPhoenixSession(
			fakeCookies("signed-session-cookie"),
			client,
		);

		expect(session).toEqual({
			principal: {
				id: "11111111-1111-1111-1111-111111111111",
				email: "u@example.com",
			},
			roles: ["member", "admin"],
		});

		// The cookie is forwarded via the `cookie` header — not a bearer `auth`.
		expect(authShowSession).toHaveBeenCalledTimes(1);
		expect(authShowSession).toHaveBeenCalledWith({
			baseUrl: "http://127.0.0.1:4000/api",
			headers: { cookie: "_dhc_session=signed-session-cookie" },
		});
	});

	it("returns null and does not call Phoenix when there is no _dhc_session cookie", async () => {
		const session = await getPhoenixSession(fakeCookies(undefined), client);

		expect(session).toBeNull();
		expect(authShowSession).not.toHaveBeenCalled();
	});

	it("returns null when Phoenix reports 401 (invalid/expired/inactive session)", async () => {
		authShowSession.mockResolvedValue({
			data: undefined,
			error: { errors: { detail: "Unauthorized" } },
		});

		const session = await getPhoenixSession(
			fakeCookies("expired-session-cookie"),
			client,
		);

		expect(session).toBeNull();
	});

	it("returns null (never throws) when the Phoenix call throws", async () => {
		authShowSession.mockRejectedValue(new Error("network down"));

		const session = await getPhoenixSession(
			fakeCookies("signed-session-cookie"),
			client,
		);

		expect(session).toBeNull();
	});

	it("returns null when Phoenix returns no data and no error", async () => {
		authShowSession.mockResolvedValue({ data: undefined, error: undefined });

		const session = await getPhoenixSession(
			fakeCookies("signed-session-cookie"),
			client,
		);

		expect(session).toBeNull();
	});
});
