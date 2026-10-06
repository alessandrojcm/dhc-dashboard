/**
 * GH-510 / ALE-344: the capability registry and the owner rule.
 *
 * This file is private to `#lib/server/authorization/index.js`. Phoenix works
 * out which capabilities a session holds (`Dhc.Auth.Capabilities`) and sends
 * them on the session projection; the dashboard never sees a role set. What
 * stays here is the part Phoenix cannot know without the page's resource:
 * which capabilities the resource owner also holds, and how a denial is
 * classified. Phoenix remains the authoritative enforcement layer; this
 * policy only decides what the dashboard shows and routes to.
 */
import type { AuthCapability } from "@dhc/api-client";
import type { PhoenixSessionProjection } from "#lib/server/auth.js";

/**
 * Every capability the dashboard can ask about. Names describe user intent,
 * not UI location. The type is the generated `AuthCapability` enum, so it is
 * the Phoenix registry by construction; `RULES` must name each one.
 */
export type Capability = AuthCapability;

/**
 * Explicit facts about the resource being accessed. Ownership is an input,
 * never a hidden lookup, so a caller cannot forget to supply it without the
 * decision visibly denying.
 */
export type ResourceContext = {
	ownerPrincipalId?: string;
};

export type AccessDecision =
	| { allowed: true }
	| {
			allowed: false;
			status: 401 | 403 | 404;
			reason: "anonymous" | "missing_capability" | "concealed_resource";
	  };

type CapabilityRule = {
	/**
	 * When set, the capability is also granted to the resource owner, and a
	 * denial conceals the resource's existence (404) instead of admitting a
	 * forbidden resource exists (403). Mirrors the Phoenix owner rule.
	 */
	ownerMayAccess?: true;
};

const RULES = {
	"beginners.workshop.read": {},
	"beginners.waitlist.toggle": {},
	"discord.assignments.manage": {},
	"discord.doctor.use": {},
	"inventory.manage": {},
	"inventory.catalog.read": {},
	"inventory.loans.own.read": {},
	"member_announcements.send": {},
	"members.directory.read": {},
	"members.invite": {},
	"members.profile.read": { ownerMayAccess: true },
	"members.profile.update": { ownerMayAccess: true },
	"members.settings.edit": {},
	"membership.reactivate": {},
	"training_announcements.manage": {},
	"workshops.manage": {},
	"workshops.own.read": {},
} satisfies Record<Capability, CapabilityRule>;

/** The capabilities named by a rule table that covers every capability. */
function capabilitiesOf(
	rules: Record<Capability, CapabilityRule>,
): Capability[] {
	// SAFETY: `RULES` is a literal checked with `satisfies Record<Capability, …>`, so its own keys are exactly the capabilities.
	return Object.keys(rules) as Capability[];
}

export const CAPABILITIES: readonly Capability[] = capabilitiesOf(RULES);

/**
 * The one place the session's capabilities, ownership and denial
 * classification meet.
 */
export function decide(
	session: PhoenixSessionProjection | null,
	capability: Capability,
	resource?: ResourceContext,
): AccessDecision {
	if (!session) return { allowed: false, status: 401, reason: "anonymous" };

	if (session.capabilities.includes(capability)) return { allowed: true };

	const rule: CapabilityRule = RULES[capability];
	if (rule.ownerMayAccess) {
		if (
			resource?.ownerPrincipalId !== undefined &&
			resource.ownerPrincipalId === session.principal.id
		) {
			return { allowed: true };
		}
		return { allowed: false, status: 404, reason: "concealed_resource" };
	}

	return { allowed: false, status: 403, reason: "missing_capability" };
}
