/**
 * GH-510: the frontend authorization boundary.
 *
 * The dashboard's routing and presentation policy — which sections a user
 * sees, which routes they may open, which actions are rendered — is decided
 * here and nowhere else. Role composition, ownership predicates, denial
 * classification, navigation filtering and route-to-capability evaluation are
 * private; callers get typed capability decisions and derived navigation.
 *
 * Everything here is *advisory UX policy*. Phoenix enforces every API
 * operation authoritatively; a frontend decision is never a security
 * substitute.
 *
 * Typical use in a server load or remote function:
 *
 * ```ts
 * const { session } = await locals.safeGetSession();
 * const access = authorizationFor(session);
 * access.require("inventory.manage");
 * ```
 *
 * Contextual access and presentation flags:
 *
 * ```ts
 * const member = { ownerPrincipalId: params.memberId };
 * access.require("members.profile.read", member);
 * return {
 *   canUpdate: access.can("members.profile.update", member),
 *   canReactivate: access.can("membership.reactivate"),
 * };
 * ```
 */
import { error } from "@sveltejs/kit";
import type { PhoenixSessionProjection } from "$lib/server/auth";
import type { NavData } from "$lib/types";
import {
	CAPABILITIES,
	decide,
	type AccessDecision,
	type Capability,
	type ResourceContext,
} from "./capabilities";
import { navigationFor } from "./navigation";
import { governingRule, type RouteParams } from "./routes";

export { CAPABILITIES };
export type { AccessDecision, Capability, ResourceContext };
export type { PhoenixSessionProjection };

export interface Authorization {
	/** `true` when the capability is granted for the given resource. */
	can(capability: Capability, resource?: ResourceContext): boolean;
	/** The full decision, including the status and reason of a denial. */
	decide(capability: Capability, resource?: ResourceContext): AccessDecision;
	/**
	 * Throws a SvelteKit `error()` carrying the decision's status (401
	 * anonymous, 403 forbidden, 404 concealed) when the capability is denied.
	 */
	require(capability: Capability, resource?: ResourceContext): void;
	/** The navigation tree containing exactly the entries this user may open. */
	navigation(): NavData;
}

const DENIAL_MESSAGES = {
	401: "Unauthorized",
	403: "Forbidden",
	404: "Not found",
} satisfies Record<401 | 403 | 404, string>;

/**
 * Builds the authorization view of a Phoenix session projection (or of an
 * anonymous request when `session` is `null`). Pure and synchronous: the
 * result depends only on the projection and on the resource context passed
 * to each call.
 */
export function authorizationFor(
	session: PhoenixSessionProjection | null,
): Authorization {
	const decideFor = (capability: Capability, resource?: ResourceContext) =>
		decide(session, capability, resource);

	return {
		can: (capability, resource) => decideFor(capability, resource).allowed,
		decide: decideFor,
		require(capability, resource) {
			const decision = decideFor(capability, resource);
			if (!decision.allowed) {
				error(decision.status, { message: DENIAL_MESSAGES[decision.status] });
			}
		},
		navigation: () =>
			navigationFor((capability) => decideFor(capability).allowed),
	};
}

export type RouteGuardOutcome =
	| { kind: "allow" }
	| { kind: "redirect"; location: string };

/**
 * Request-hook adapter: evaluates the protected-route rule governing a
 * SvelteKit route id with the same decisions `authorizationFor` exposes.
 * Ungated routes always allow. The hook turns a `redirect` outcome into a
 * SvelteKit `redirect(303, location)`.
 */
export function guardRoute(
	session: PhoenixSessionProjection | null,
	route: { id: string | null; params: RouteParams },
): RouteGuardOutcome {
	const rule = governingRule(route.id);
	if (!rule) return { kind: "allow" };

	if (!session) return { kind: "redirect", location: "/auth" };

	const resource = rule.resource?.(route.params);
	if (decide(session, rule.requires, resource).allowed) {
		return { kind: "allow" };
	}

	switch (rule.onDeny) {
		case "redirect-to-own-profile":
			return {
				kind: "redirect",
				location: `/dashboard/members/${session.principal.id}`,
			};
	}
}
