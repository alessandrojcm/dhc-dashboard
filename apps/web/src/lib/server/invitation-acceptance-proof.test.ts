import { describe, expect, it, vi } from "vitest";
import {
	clearInvitationAcceptanceProof,
	hasInvitationAcceptanceProof,
	invitationAcceptanceApiOptions,
	relayInvitationAcceptanceProof,
} from "$lib/server/invitation-acceptance-proof";

describe("Invitation Acceptance proof", () => {
	it("attaches a present proof only to the trusted Phoenix request", () => {
		const cookies = {
			get: vi.fn(() => "signed-proof"),
		};

		expect(invitationAcceptanceApiOptions(cookies)).toMatchObject({
			credentials: "include",
			headers: {
				cookie: "_dhc_onboarding_acceptance=signed-proof",
			},
		});
	});

	it("does not attach a proof header when the browser has no proof", () => {
		const cookies = {
			get: vi.fn(() => undefined),
		};

		expect(invitationAcceptanceApiOptions(cookies)).toMatchObject({
			credentials: "include",
			headers: undefined,
		});
	});

	it("relays only the named proof with its standard browser lifetime", () => {
		const cookies = {
			set: vi.fn(),
		};
		const headers = new Headers({
			"set-cookie":
				"unrelated=ignored; Path=/, _dhc_onboarding_acceptance=replacement-proof; Path=/api/onboarding/invitation-acceptance; Max-Age=900; HttpOnly; SameSite=Lax",
		});

		expect(relayInvitationAcceptanceProof(cookies, headers)).toBe(true);
		expect(cookies.set).toHaveBeenCalledTimes(1);
		expect(cookies.set).toHaveBeenCalledWith(
			"_dhc_onboarding_acceptance",
			"replacement-proof",
			{
				encode: expect.any(Function),
				httpOnly: true,
				maxAge: 15 * 60,
				path: "/",
				sameSite: "lax",
				secure: false,
			},
		);
		const options = cookies.set.mock.calls[0][2];
		expect(options.encode("replacement-proof")).toBe("replacement-proof");
	});

	it("ignores malformed and unrelated response cookies", () => {
		const cookies = {
			set: vi.fn(),
		};
		const headers = new Headers({
			"set-cookie":
				"_dhc_onboarding_acceptance=pathless, unrelated=value; Path=/",
		});

		expect(relayInvitationAcceptanceProof(cookies, headers)).toBe(false);
		expect(cookies.set).not.toHaveBeenCalled();
	});

	it("reports and clears the browser proof through the same interface", () => {
		const cookies = {
			get: vi.fn(() => "signed-proof"),
			delete: vi.fn(),
		};

		expect(hasInvitationAcceptanceProof(cookies)).toBe(true);
		clearInvitationAcceptanceProof(cookies);

		expect(cookies.delete).toHaveBeenCalledWith("_dhc_onboarding_acceptance", {
			path: "/",
		});
	});
});
