import { describe, expect, it, vi } from "vitest";
import {
	isHttpError,
	isRedirect,
	type Cookies,
	type HttpError,
	type Redirect,
} from "@sveltejs/kit";
import { applyInvitationRouteOutcome, applyRouteEffects } from "./apply";
import {
	consumeInvitationSignInPrefill,
	sveltekitAcceptanceCookies,
} from "./cookie-store";
import { decideInvitationRoute } from "./decision";
import { acceptanceView, recordingCookieStore } from "./testing";

function fakeCookies(initial: Record<string, string> = {}) {
	const jar = new Map(Object.entries(initial));
	const operations: string[] = [];
	return {
		operations,
		cookies: {
			get: vi.fn((name: string) => jar.get(name)),
			set: vi.fn<Cookies["set"]>((name, value) => {
				jar.set(name, value);
				operations.push(`set:${name}`);
			}),
			delete: vi.fn<Cookies["delete"]>((name) => {
				jar.delete(name);
				operations.push(`delete:${name}`);
			}),
		},
	};
}

/** Run a route adapter and return the SvelteKit redirect/error it threw. */
function capture(run: () => void): Redirect | HttpError | undefined {
	try {
		run();
	} catch (thrown) {
		if (isRedirect(thrown) || isHttpError(thrown)) return thrown;
		throw thrown;
	}
	return undefined;
}

describe("applyInvitationRouteOutcome", () => {
	it("accepted: prefills sign-in, clears the proof, then redirects to success", () => {
		const { cookies, operations } = fakeCookies({
			_dhc_onboarding_acceptance: "proof",
		});
		const store = sveltekitAcceptanceCookies(cookies);
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result: acceptanceView("accepted", {
				invitationEmail: "invitee@example.com",
			}),
		});

		const thrown = capture(() =>
			applyInvitationRouteOutcome(outcome, {
				cookies: store,
				invitationId: "invitation-id",
				mode: "render",
			}),
		);

		expect(operations).toEqual([
			"set:invitation-sign-in-prefill",
			"delete:_dhc_onboarding_acceptance",
		]);
		expect(cookies.set).toHaveBeenCalledWith(
			"invitation-sign-in-prefill",
			"invitee@example.com",
			{
				httpOnly: true,
				maxAge: 10 * 60,
				path: "/auth",
				sameSite: "lax",
				secure: false,
			},
		);
		expect(isRedirect(thrown)).toBe(true);
		expect(thrown).toMatchObject({
			status: 303,
			location: "/members/signup/invitation-id/success",
		});
	});

	it("accepted without an email still clears the proof and redirects", () => {
		const { cookies, operations } = fakeCookies({
			_dhc_onboarding_acceptance: "proof",
		});
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result: acceptanceView("accepted"),
		});

		const thrown = capture(() =>
			applyInvitationRouteOutcome(outcome, {
				cookies: sveltekitAcceptanceCookies(cookies),
				invitationId: "invitation-id",
				mode: "redirect",
			}),
		);

		expect(operations).toEqual(["delete:_dhc_onboarding_acceptance"]);
		expect(isRedirect(thrown)).toBe(true);
	});

	it("restart in render mode returns the restart view after clearing the proof", () => {
		const store = recordingCookieStore({ proof: "proof" });

		const view = applyInvitationRouteOutcome(
			decideInvitationRoute({ hasAcceptanceProof: false }),
			{ cookies: store.cookies, invitationId: "inv", mode: "render" },
		);

		expect(view).toEqual({ state: "restartVerification" });
		expect(store.effects).toEqual([{ type: "clearProof" }]);
	});

	it("show in render mode returns the Phoenix view untouched", () => {
		const store = recordingCookieStore({ proof: "proof" });

		const view = applyInvitationRouteOutcome(
			decideInvitationRoute({
				hasAcceptanceProof: true,
				result: acceptanceView("paymentReady", { complimentary: true }),
			}),
			{ cookies: store.cookies, invitationId: "inv", mode: "render" },
		);

		expect(view).toEqual({ state: "paymentReady", complimentary: true });
		expect(store.effects).toEqual([]);
	});

	it.each(["SHOW", "RESTART_VERIFICATION"] as const)(
		"%s in redirect mode sends the browser back to the invitation page",
		(type) => {
			const store = recordingCookieStore({ proof: "proof" });
			const outcome =
				type === "SHOW"
					? decideInvitationRoute({
							hasAcceptanceProof: true,
							result: acceptanceView("paymentPending"),
						})
					: decideInvitationRoute({ hasAcceptanceProof: false });

			const thrown = capture(() =>
				applyInvitationRouteOutcome(outcome, {
					cookies: store.cookies,
					invitationId: "inv",
					mode: "redirect",
				}),
			);

			expect(thrown).toMatchObject({
				status: 303,
				location: "/members/signup/inv",
			});
		},
	);

	it("unavailable becomes a 503 and keeps the proof", () => {
		const store = recordingCookieStore({ proof: "proof" });

		const thrown = capture(() =>
			applyInvitationRouteOutcome(
				decideInvitationRoute({
					hasAcceptanceProof: true,
					result: { kind: "unavailable", reason: "network" },
				}),
				{ cookies: store.cookies, invitationId: "inv", mode: "render" },
			),
		);

		expect(isHttpError(thrown)).toBe(true);
		expect(thrown).toMatchObject({ status: 503 });
		expect(store.proof).toBe("proof");
	});

	it("rejected surfaces the Phoenix status and detail", () => {
		const store = recordingCookieStore({ proof: "proof" });

		const thrown = capture(() =>
			applyInvitationRouteOutcome(
				decideInvitationRoute({
					hasAcceptanceProof: true,
					result: { kind: "rejected", httpStatus: 400, detail: "bad" },
				}),
				{ cookies: store.cookies, invitationId: "inv", mode: "render" },
			),
		);

		expect(thrown).toMatchObject({ status: 400, body: { message: "bad" } });
	});
});

describe("SvelteKit acceptance cookie adapter", () => {
	it("stores the issued proof with its browser lifetime and no re-encoding", () => {
		const { cookies } = fakeCookies();

		applyRouteEffects(
			[{ type: "storeProof", proof: "issued-proof" }],
			sveltekitAcceptanceCookies(cookies),
		);

		expect(cookies.set).toHaveBeenCalledWith(
			"_dhc_onboarding_acceptance",
			"issued-proof",
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
		expect(options.encode?.("a=b")).toBe("a=b");
	});

	it("consumes the sign-in prefill exactly once", () => {
		const { cookies } = fakeCookies({
			"invitation-sign-in-prefill": "invitee@example.com",
		});

		expect(consumeInvitationSignInPrefill(cookies)).toBe("invitee@example.com");
		expect(consumeInvitationSignInPrefill(cookies)).toBeUndefined();
		expect(cookies.delete).toHaveBeenCalledTimes(1);
		expect(cookies.delete).toHaveBeenCalledWith("invitation-sign-in-prefill", {
			path: "/auth",
		});
	});
});
