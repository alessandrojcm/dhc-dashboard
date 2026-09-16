/**
 * GH-510: the capability registry and its role-to-capability policy.
 *
 * This file is private to `$lib/server/authorization`. Feature code never
 * imports role sets; it asks `authorizationFor(session)` about a capability.
 * Role names come from the Phoenix session projection and mirror the Phoenix
 * router pipelines — Phoenix remains the authoritative enforcement layer, this
 * policy only decides what the dashboard shows and routes to.
 */
import type { PhoenixSessionProjection } from "$lib/server/auth";

/**
 * Every capability the dashboard can ask about. Names describe user intent,
 * not UI location. This tuple is the single source of the `Capability` type.
 */
export const CAPABILITIES = [
	"beginners.workshop.read",
	"beginners.waitlist.toggle",
	"discord.doctor.use",
	"inventory.manage",
	"inventory.catalog.read",
	"inventory.loans.own.read",
	"members.directory.read",
	"members.invite",
	"members.profile.read",
	"members.profile.update",
	"members.settings.edit",
	"membership.reactivate",
	"workshops.manage",
	"workshops.own.read",
] as const;

export type Capability = (typeof CAPABILITIES)[number];

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

// ---------------------------------------------------------------------------
// Role sets (private). Each mirrors a Phoenix router pipeline.
// ---------------------------------------------------------------------------

/** Club officers: president, admin and the committee coordinator. */
const OFFICERS = ["president", "admin", "committee_coordinator"];

/**
 * ALE-252: officers with billing authority who may mint membership charges
 * (reactivation). Mirrors the Phoenix `:membership_minting_api` pipeline;
 * deliberately narrower than the member administrators and with no
 * self-service fallback, because the command creates new Stripe charges.
 */
const BILLING_AUTHORITY = [...OFFICERS, "treasurer"];

/** Every committee/coach role that may see the member directory. */
const MEMBER_ADMINISTRATORS = [
	...BILLING_AUTHORITY,
	"sparring_coordinator",
	"workshop_coordinator",
	"beginners_coordinator",
	"quartermaster",
	"pr_manager",
	"volunteer_coordinator",
	"research_coordinator",
	"coach",
];

const WORKSHOP_COORDINATORS = ["workshop_coordinator", "president", "admin"];

/** Mirrors Phoenix inventory writes (`quartermaster`, `admin`, `president`). */
const INVENTORY_OPERATORS = ["quartermaster", "admin", "president"];

const BEGINNERS_STAFF = [...OFFICERS, "coach", "beginners_coordinator"];

/** Every authenticated user carries the `member` role. */
const MEMBERS = ["member"];

type CapabilityRule = {
	/** Roles that hold the capability regardless of resource context. */
	roles: readonly string[];
	/**
	 * When set, the capability is also granted to the resource owner, and a
	 * denial conceals the resource's existence (404) instead of admitting a
	 * forbidden resource exists (403).
	 */
	ownerMayAccess?: true;
};

const RULES = {
	"beginners.workshop.read": { roles: BEGINNERS_STAFF },
	"beginners.waitlist.toggle": { roles: OFFICERS },
	"discord.doctor.use": { roles: OFFICERS },
	"inventory.manage": { roles: INVENTORY_OPERATORS },
	"inventory.catalog.read": { roles: MEMBERS },
	"inventory.loans.own.read": { roles: MEMBERS },
	"members.directory.read": { roles: MEMBER_ADMINISTRATORS },
	"members.invite": { roles: OFFICERS },
	"members.profile.read": {
		roles: MEMBER_ADMINISTRATORS,
		ownerMayAccess: true,
	},
	"members.profile.update": {
		roles: MEMBER_ADMINISTRATORS,
		ownerMayAccess: true,
	},
	"members.settings.edit": { roles: OFFICERS },
	"membership.reactivate": { roles: BILLING_AUTHORITY },
	"workshops.manage": { roles: WORKSHOP_COORDINATORS },
	"workshops.own.read": { roles: MEMBERS },
} satisfies Record<Capability, CapabilityRule>;

/**
 * The one place role composition, ownership and denial classification meet.
 */
export function decide(
	session: PhoenixSessionProjection | null,
	capability: Capability,
	resource?: ResourceContext,
): AccessDecision {
	if (!session) return { allowed: false, status: 401, reason: "anonymous" };

	const rule: CapabilityRule = RULES[capability];
	if (rule.roles.some((role) => session.roles.includes(role))) {
		return { allowed: true };
	}

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
