import { assign, initialTransition, setup, transition } from "xstate";
import * as v from "valibot";
import type {
	AcceptanceApiResult,
	AcceptanceView,
} from "$lib/invitation-acceptance/vocabulary";

/**
 * Pure server decision machine (GH-509).
 *
 * Maps request-local evidence (does this browser hold acceptance proof?) plus
 * one typed Phoenix result onto an explicit route outcome and the cookie
 * effects that outcome requires. It runs through XState's pure transition
 * functions only — no actor is ever created, so nothing here can leak across
 * SvelteKit requests. Phoenix remains the only authority on durable state;
 * this machine decides *how the route reacts* to what Phoenix said.
 */

export type RouteEffect =
	| { type: "clearAcceptanceProof" }
	| { type: "storeProof"; proof: string }
	| { type: "establishSignInHandoff"; invitationEmail: string | undefined };

export type InvitationRouteOutcome =
	| { type: "SHOW"; view: AcceptanceView; effects: RouteEffect[] }
	| {
			type: "REDIRECT_TO_SUCCESS";
			view: AcceptanceView;
			effects: RouteEffect[];
	  }
	| { type: "RESTART_VERIFICATION"; effects: RouteEffect[] }
	| {
			type: "UNAVAILABLE";
			reason: "timeout" | "network";
			detail: string | undefined;
			effects: RouteEffect[];
	  }
	| {
			type: "REJECTED";
			httpStatus: number;
			detail: string | undefined;
			effects: RouteEffect[];
	  };

export type InvitationDecisionInput = {
	hasAcceptanceProof: boolean;
	result?: AcceptanceApiResult;
};

type DecisionContext = {
	hasAcceptanceProof: boolean;
	result: AcceptanceApiResult | undefined;
};

type DecisionEvent = {
	type: "PHOENIX_RESULT_RECEIVED";
	result: AcceptanceApiResult;
};

type WithoutEffects<T> = T extends { effects: RouteEffect[] }
	? Omit<T, "effects">
	: never;

/** A final state's output: the outcome minus its effects, which come from actions. */
type DecisionOutput = WithoutEffects<InvitationRouteOutcome>;

const RESTART_HTTP_STATUS = 409;

function resultOf(event: DecisionEvent) {
	return event.result;
}

const handoffParamsSchema = v.object({
	invitationEmail: v.optional(v.string()),
});

export const invitationDecisionMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as DecisionContext,
		events: {} as DecisionEvent,
		input: {} as InvitationDecisionInput,
		output: {} as DecisionOutput,
	},
	guards: {
		lacksProof: ({ context }) => !context.hasAcceptanceProof,
		accepted: ({ event }) => {
			const result = resultOf(event);
			return result.kind === "view" && result.view.state === "accepted";
		},
		restartVerification: ({ event }) => {
			const result = resultOf(event);
			if (result.kind === "view")
				return result.view.state === "restartVerification";
			return (
				result.kind === "rejected" && result.httpStatus === RESTART_HTTP_STATUS
			);
		},
		unavailable: ({ event }) => {
			const result = resultOf(event);
			return (
				result.kind === "unavailable" ||
				(result.kind === "rejected" && result.httpStatus >= 500)
			);
		},
		unexpectedResponse: ({ event }) =>
			resultOf(event).kind === "unexpected_response",
		rejected: ({ event }) => resultOf(event).kind === "rejected",
	},
	actions: {
		// Effects are *requested* here and executed by `applyInvitationRouteOutcome`.
		clearAcceptanceProof: () => {},
		establishSignInHandoff: (
			_,
			_params: { invitationEmail: string | undefined },
		) => {},
	},
}).createMachine({
	id: "invitationRouteDecision",
	context: ({ input }) => ({
		hasAcceptanceProof: input.hasAcceptanceProof,
		result: input.result,
	}),
	initial: "evaluating",
	states: {
		evaluating: {
			always: [
				{ guard: "lacksProof", target: "restartVerification" },
				{ target: "awaitingPhoenix" },
			],
		},
		awaitingPhoenix: {
			on: {
				PHOENIX_RESULT_RECEIVED: [
					{
						guard: "accepted",
						target: "redirectToSuccess",
						actions: assign({ result: ({ event }) => event.result }),
					},
					{ guard: "restartVerification", target: "restartVerification" },
					{
						guard: "unexpectedResponse",
						target: "rejected",
						actions: assign({ result: ({ event }) => event.result }),
					},
					{
						guard: "unavailable",
						target: "unavailable",
						actions: assign({ result: ({ event }) => event.result }),
					},
					{
						guard: "rejected",
						target: "rejected",
						actions: assign({ result: ({ event }) => event.result }),
					},
					{
						target: "show",
						actions: assign({ result: ({ event }) => event.result }),
					},
				],
			},
		},
		show: {
			type: "final",
			output: ({ context }) => ({
				type: "SHOW" as const,
				view: viewOf(context.result),
			}),
		},
		redirectToSuccess: {
			type: "final",
			entry: [
				{
					type: "establishSignInHandoff",
					params: ({ context }) => ({
						invitationEmail: viewOf(context.result).invitationEmail,
					}),
				},
				{ type: "clearAcceptanceProof" },
			],
			output: ({ context }) => ({
				type: "REDIRECT_TO_SUCCESS" as const,
				view: viewOf(context.result),
			}),
		},
		restartVerification: {
			type: "final",
			entry: [{ type: "clearAcceptanceProof" }],
			output: () => ({ type: "RESTART_VERIFICATION" as const }),
		},
		unavailable: {
			type: "final",
			output: ({ context }) => {
				const result = context.result;
				if (result?.kind === "unavailable")
					return {
						type: "UNAVAILABLE" as const,
						reason: result.reason,
						detail: result.detail,
					};
				return {
					type: "UNAVAILABLE" as const,
					reason: "network" as const,
					detail: result?.kind === "rejected" ? result.detail : undefined,
				};
			},
		},
		rejected: {
			type: "final",
			output: ({ context }) => {
				const result = context.result;
				if (result?.kind === "unexpected_response") {
					return {
						type: "REJECTED" as const,
						httpStatus: 502,
						detail: result.detail,
					};
				}
				return {
					type: "REJECTED" as const,
					httpStatus: result?.kind === "rejected" ? result.httpStatus : 500,
					detail: result?.kind === "rejected" ? result.detail : undefined,
				};
			},
		},
	},
	// SAFETY: every final state above declares an `output` of type
	// `DecisionOutput`; the root output only forwards the done-state event's.
	output: ({ event }) => event.output as DecisionOutput,
});

function viewOf(result: AcceptanceApiResult | undefined): AcceptanceView {
	if (result?.kind !== "view") {
		throw new Error(
			"invitationDecisionMachine reached a view state without a view",
		);
	}
	return result.view;
}

/**
 * Decide how a route should react to the current evidence. Pure: the same
 * input always yields the same outcome, and the cookie effects are returned
 * rather than performed.
 */
export function decideInvitationRoute(
	input: InvitationDecisionInput,
): InvitationRouteOutcome {
	const [initial, initialActions] = initialTransition(
		invitationDecisionMachine,
		{ hasAcceptanceProof: input.hasAcceptanceProof },
	);

	let snapshot = initial;
	let actions = initialActions;

	if (snapshot.status !== "done") {
		if (!input.result) {
			throw new Error(
				"decideInvitationRoute requires a Phoenix result when the browser holds proof",
			);
		}
		[snapshot, actions] = transition(invitationDecisionMachine, snapshot, {
			type: "PHOENIX_RESULT_RECEIVED",
			result: input.result,
		});
	}

	if (snapshot.status !== "done" || !snapshot.output) {
		throw new Error("invitationDecisionMachine did not reach an outcome");
	}

	const effects: RouteEffect[] = [];
	for (const action of actions) {
		if (action.type === "clearAcceptanceProof") {
			effects.push({ type: "clearAcceptanceProof" });
		} else if (action.type === "establishSignInHandoff") {
			const params = v.safeParse(handoffParamsSchema, action.params);
			effects.push({
				type: "establishSignInHandoff",
				invitationEmail: params.success
					? params.output.invitationEmail
					: undefined,
			});
		}
	}

	return { ...snapshot.output, effects };
}
