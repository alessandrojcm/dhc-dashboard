import { describe, expect, it, vi } from "vitest";
import { isRedirect } from "@sveltejs/kit";
import {
	completeInvitationAcceptance,
	consumeInvitationSignInPrefill,
} from "$lib/server/post-acceptance-sign-in-handoff";

describe("post-acceptance sign-in handoff", () => {
	it("prepares ordinary sign-in, clears the acceptance proof, then redirects", () => {
		const operations: string[] = [];
		const cookies = {
			set: vi.fn((name: string) => operations.push(`set:${name}`)),
			delete: vi.fn((name: string) => operations.push(`delete:${name}`)),
		};

		let thrown: unknown;
		try {
			completeInvitationAcceptance(
				cookies,
				"invitee@example.com",
				"invitation-id",
			);
		} catch (error) {
			thrown = error;
			operations.push("redirect");
		}

		expect(operations).toEqual([
			"set:invitation-sign-in-prefill",
			"delete:_dhc_onboarding_acceptance",
			"redirect",
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

	it("consumes the sign-in prefill exactly once", () => {
		let prefill: string | undefined = "invitee@example.com";
		const cookies = {
			get: vi.fn(() => prefill),
			delete: vi.fn(() => {
				prefill = undefined;
			}),
		};

		expect(consumeInvitationSignInPrefill(cookies)).toBe("invitee@example.com");
		expect(consumeInvitationSignInPrefill(cookies)).toBeUndefined();
		expect(cookies.delete).toHaveBeenCalledTimes(1);
		expect(cookies.delete).toHaveBeenCalledWith("invitation-sign-in-prefill", {
			path: "/auth",
		});
	});
});
