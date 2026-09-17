import { describe, expect, it } from "vitest";
import { decideInvitationRoute, type InvitationRouteOutcome } from "./decision";
import type { AcceptanceApiResult } from "$lib/invitation-acceptance/vocabulary";
import { acceptanceView as view } from "./testing";

const effectTypes = (outcome: InvitationRouteOutcome) =>
	outcome.effects.map((effect) => effect.type);

describe("decideInvitationRoute", () => {
	it("restarts verification and clears the proof when the browser holds no proof", () => {
		const outcome = decideInvitationRoute({ hasAcceptanceProof: false });

		expect(outcome.type).toBe("RESTART_VERIFICATION");
		expect(effectTypes(outcome)).toEqual(["clearAcceptanceProof"]);
	});

	it("never consults a Phoenix result without proof", () => {
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: false,
			result: view("accepted", { invitationEmail: "a@example.com" }),
		});

		expect(outcome.type).toBe("RESTART_VERIFICATION");
	});

	it("redirects to success and establishes the sign-in handoff exactly once for accepted", () => {
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result: view("accepted", { invitationEmail: "invitee@example.com" }),
		});

		expect(outcome).toMatchObject({
			type: "REDIRECT_TO_SUCCESS",
			view: { state: "accepted", invitationEmail: "invitee@example.com" },
		});
		expect(outcome.effects).toEqual([
			{
				type: "establishSignInHandoff",
				invitationEmail: "invitee@example.com",
			},
			{ type: "clearAcceptanceProof" },
		]);
	});

	it.each([
		["a 200 restartVerification view", view("restartVerification")],
		["a 409 restart_verification view", view("restartVerification", {}, 409)],
		[
			"a 409 without a state body",
			{ kind: "rejected", httpStatus: 409 } satisfies AcceptanceApiResult,
		],
	])("restarts verification and clears the proof on %s", (_label, result) => {
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result,
		});

		expect(outcome.type).toBe("RESTART_VERIFICATION");
		expect(effectTypes(outcome)).toEqual(["clearAcceptanceProof"]);
	});

	it.each([
		"awaitingDiscord",
		"discordVerified",
		"discordCollision",
		"discordUnavailable",
		"paymentReady",
		"paymentPending",
		"paymentNeedsAction",
		"paymentTerminal",
	] as const)("shows %s without touching cookies", (state) => {
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result: view(state, { retryAllowed: true }),
		});

		expect(outcome).toMatchObject({
			type: "SHOW",
			view: { state, retryAllowed: true },
			effects: [],
		});
	});

	it("keeps the proof when Phoenix is unavailable", () => {
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result: { kind: "unavailable", reason: "timeout" },
		});

		expect(outcome).toEqual({
			type: "UNAVAILABLE",
			reason: "timeout",
			detail: undefined,
			effects: [],
		});
	});

	it("keeps the proof on a 5xx and reports it as unavailable", () => {
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result: {
				kind: "rejected",
				httpStatus: 503,
				detail: "recovery scheduled",
			},
		});

		expect(outcome).toMatchObject({
			type: "UNAVAILABLE",
			reason: "network",
			detail: "recovery scheduled",
			effects: [],
		});
	});

	it("reports other rejections explicitly without clearing the proof", () => {
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result: { kind: "rejected", httpStatus: 422, detail: "malformed" },
		});

		expect(outcome).toEqual({
			type: "REJECTED",
			httpStatus: 422,
			detail: "malformed",
			effects: [],
		});
	});

	it("maps an unparseable success to a 502 rejection without clearing the proof", () => {
		const outcome = decideInvitationRoute({
			hasAcceptanceProof: true,
			result: { kind: "unexpected_response", httpStatus: 200 },
		});

		expect(outcome).toEqual({
			type: "REJECTED",
			httpStatus: 502,
			detail: undefined,
			effects: [],
		});
	});

	it("is a pure function: two identical decisions are independent", () => {
		const input = {
			hasAcceptanceProof: true,
			result: view("accepted", { invitationEmail: "x@example.com" }),
		};

		expect(decideInvitationRoute(input)).toEqual(decideInvitationRoute(input));
	});
});
