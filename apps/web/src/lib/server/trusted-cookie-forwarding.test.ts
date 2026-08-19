import { describe, expect, it, vi } from "vitest";
import {
	forwardTrustedResponseCookie,
	forwardTrustedResponseCookies,
	type CookieWriter,
} from "$lib/server/trusted-cookie-forwarding";

function cookieWriter() {
	return {
		set: vi.fn<CookieWriter["set"]>(),
	};
}

describe("trusted Phoenix cookie forwarding", () => {
	it("forwards a cookie with the attributes selected by Phoenix", () => {
		const cookies = cookieWriter();
		const headers = new Headers({
			"set-cookie":
				"_dhc_session=signed-value; Path=/Auth/Callback; Max-Age=600; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly; Secure; SameSite=Lax",
		});

		expect(forwardTrustedResponseCookies(cookies, headers)).toEqual([
			"_dhc_session",
		]);
		expect(cookies.set).toHaveBeenCalledTimes(1);

		const [name, value, options] = cookies.set.mock.calls[0];
		expect(name).toBe("_dhc_session");
		expect(value).toBe("signed-value");
		expect(options).toMatchObject({
			path: "/Auth/Callback",
			maxAge: 600,
			expires: new Date("Wed, 21 Oct 2026 07:28:00 GMT"),
			httpOnly: true,
			secure: true,
			sameSite: "lax",
		});
		expect(options.encode).toBeTypeOf("function");
		expect(options.encode?.("signed-value")).toBe("signed-value");
	});

	it("forwards multiple cookies without splitting the comma in Expires", () => {
		const cookies = cookieWriter();
		const headers = new Headers({
			"set-cookie":
				"_dhc_session=first; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/; HttpOnly, discord_oauth_state=second; Path=/auth/discord/callback; Max-Age=300; Secure; SameSite=None",
		});

		expect(forwardTrustedResponseCookies(cookies, headers)).toEqual([
			"_dhc_session",
			"discord_oauth_state",
		]);
		expect(cookies.set).toHaveBeenNthCalledWith(
			1,
			"_dhc_session",
			"first",
			expect.objectContaining({
				expires: new Date("Wed, 21 Oct 2026 07:28:00 GMT"),
				path: "/",
				httpOnly: true,
			}),
		);
		expect(cookies.set).toHaveBeenNthCalledWith(
			2,
			"discord_oauth_state",
			"second",
			expect.objectContaining({
				maxAge: 300,
				path: "/auth/discord/callback",
				secure: true,
				sameSite: "none",
			}),
		);
	});

	it("ignores malformed cookies and unsupported attribute values", () => {
		const cookies = cookieWriter();
		const overflowingMaxAge = "9".repeat(400);
		const headers = new Headers({
			"set-cookie": `missing-value, =missing-name; Path=/, pathless=value, valid=value; Path=/kept; Max-Age=${overflowingMaxAge}; Expires=not-a-date; SameSite=invalid; Domain=bad domain`,
		});

		expect(forwardTrustedResponseCookies(cookies, headers)).toEqual(["valid"]);
		expect(cookies.set).toHaveBeenCalledTimes(1);
		expect(cookies.set).toHaveBeenCalledWith(
			"valid",
			"value",
			expect.objectContaining({ path: "/kept" }),
		);

		const options = cookies.set.mock.calls[0][2];
		expect(options).not.toHaveProperty("maxAge");
		expect(options).not.toHaveProperty("expires");
		expect(options.sameSite).toBe(false);
		expect(options).not.toHaveProperty("domain");
	});

	it("does nothing when the response has no Set-Cookie header", () => {
		const cookies = cookieWriter();

		expect(forwardTrustedResponseCookies(cookies, new Headers())).toEqual([]);
		expect(cookies.set).not.toHaveBeenCalled();
	});

	it("does not replace omitted upstream attributes with SvelteKit defaults", () => {
		const cookies = cookieWriter();
		const headers = new Headers({
			"set-cookie": "oauth_state=signed-value; Path=/",
		});

		expect(forwardTrustedResponseCookies(cookies, headers)).toEqual([
			"oauth_state",
		]);
		expect(cookies.set).toHaveBeenCalledWith(
			"oauth_state",
			"signed-value",
			expect.objectContaining({
				httpOnly: false,
				sameSite: false,
				secure: false,
			}),
		);
	});

	it("forwards only the requested trusted cookie", () => {
		const cookies = cookieWriter();
		const headers = new Headers({
			"set-cookie":
				"_dhc_onboarding_acceptance=proof; Path=/, _dhc_key=oauth-state; Path=/auth/discord/callback; HttpOnly",
		});

		expect(forwardTrustedResponseCookie(cookies, headers, "_dhc_key")).toBe(
			true,
		);
		expect(cookies.set).toHaveBeenCalledTimes(1);
		expect(cookies.set).toHaveBeenCalledWith(
			"_dhc_key",
			"oauth-state",
			expect.objectContaining({
				path: "/auth/discord/callback",
				httpOnly: true,
			}),
		);
	});
});
