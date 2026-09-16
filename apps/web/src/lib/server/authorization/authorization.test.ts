import { describe, expect, it } from "vitest";
import {
	authorizationFor,
	CAPABILITIES,
	guardRoute,
	type Capability,
	type PhoenixSessionProjection,
} from "$lib/server/authorization";

/**
 * GH-510: behavioural tests for the frontend authorization boundary.
 *
 * Everything is observed through `authorizationFor(session)` and
 * `guardRoute(session, route)`; role sets, navigation definitions and
 * protected-route rules are private implementation details. Changing a role
 * assignment must show up as exactly one intentional diff in the tables below.
 */

const SELF = "11111111-1111-1111-1111-111111111111";
const OTHER = "22222222-2222-2222-2222-222222222222";

function session(...roles: string[]): PhoenixSessionProjection {
	return { principal: { id: SELF, email: "u@example.com" }, roles };
}

const EVERY_ROLE = [
	"admin",
	"president",
	"treasurer",
	"committee_coordinator",
	"sparring_coordinator",
	"workshop_coordinator",
	"beginners_coordinator",
	"quartermaster",
	"pr_manager",
	"volunteer_coordinator",
	"research_coordinator",
	"coach",
	"member",
] as const;

/**
 * Role → capability policy table. One row per capability; the listed roles are
 * the only ones allowed (without resource context). Every other known role
 * must be denied.
 */
const POLICY = {
	"beginners.workshop.read": [
		"admin",
		"committee_coordinator",
		"coach",
		"beginners_coordinator",
		"president",
	],
	"beginners.waitlist.toggle": ["admin", "president", "committee_coordinator"],
	"discord.doctor.use": ["admin", "president", "committee_coordinator"],
	"inventory.manage": ["quartermaster", "admin", "president"],
	"inventory.catalog.read": ["member"],
	"inventory.loans.own.read": ["member"],
	"members.directory.read": [
		"admin",
		"president",
		"treasurer",
		"committee_coordinator",
		"sparring_coordinator",
		"workshop_coordinator",
		"beginners_coordinator",
		"quartermaster",
		"pr_manager",
		"volunteer_coordinator",
		"research_coordinator",
		"coach",
	],
	"members.invite": ["admin", "president", "committee_coordinator"],
	"members.profile.read": [
		"admin",
		"president",
		"treasurer",
		"committee_coordinator",
		"sparring_coordinator",
		"workshop_coordinator",
		"beginners_coordinator",
		"quartermaster",
		"pr_manager",
		"volunteer_coordinator",
		"research_coordinator",
		"coach",
	],
	"members.profile.update": [
		"admin",
		"president",
		"treasurer",
		"committee_coordinator",
		"sparring_coordinator",
		"workshop_coordinator",
		"beginners_coordinator",
		"quartermaster",
		"pr_manager",
		"volunteer_coordinator",
		"research_coordinator",
		"coach",
	],
	"members.settings.edit": ["admin", "president", "committee_coordinator"],
	"membership.reactivate": [
		"admin",
		"president",
		"treasurer",
		"committee_coordinator",
	],
	"workshops.manage": ["workshop_coordinator", "president", "admin"],
	"workshops.own.read": ["member"],
} satisfies Record<Capability, readonly string[]>;

describe("authorizationFor — capability registry", () => {
	it("the policy table covers exactly the typed registry", () => {
		expect(Object.keys(POLICY).sort()).toEqual([...CAPABILITIES].sort());
	});

	describe.each(CAPABILITIES)("%s", (capability) => {
		const allowed = POLICY[capability];
		const denied = EVERY_ROLE.filter((role) => !allowed.includes(role));

		it.each(allowed)("allows %s", (role) => {
			expect(authorizationFor(session(role)).can(capability)).toBe(true);
		});

		it.each(denied)("denies %s", (role) => {
			expect(authorizationFor(session(role)).can(capability)).toBe(false);
		});

		it("gives anonymous sessions an unauthenticated decision", () => {
			expect(authorizationFor(null).decide(capability)).toEqual({
				allowed: false,
				status: 401,
				reason: "anonymous",
			});
		});
	});
});

describe("authorizationFor — decisions", () => {
	it("inventory operators can manage inventory, ordinary members cannot", () => {
		expect(
			authorizationFor(session("quartermaster")).can("inventory.manage"),
		).toBe(true);
		expect(
			authorizationFor(session("member")).decide("inventory.manage"),
		).toEqual({ allowed: false, status: 403, reason: "missing_capability" });
	});

	it("member administrators can read and update another member's profile", () => {
		const access = authorizationFor(session("coach"));
		const other = { ownerPrincipalId: OTHER };
		expect(access.can("members.profile.read", other)).toBe(true);
		expect(access.can("members.profile.update", other)).toBe(true);
	});

	it("ordinary members can read/update their own profile", () => {
		const access = authorizationFor(session("member"));
		const own = { ownerPrincipalId: SELF };
		expect(access.decide("members.profile.read", own)).toEqual({
			allowed: true,
		});
		expect(access.can("members.profile.update", own)).toBe(true);
	});

	it("ordinary members receive a concealed denial for another member's profile", () => {
		const access = authorizationFor(session("member"));
		const other = { ownerPrincipalId: OTHER };
		const concealed = {
			allowed: false,
			status: 404,
			reason: "concealed_resource",
		};
		expect(access.decide("members.profile.read", other)).toEqual(concealed);
		expect(access.decide("members.profile.update", other)).toEqual(concealed);
		// Without resource context ownership cannot be established either.
		expect(access.decide("members.profile.read")).toEqual(concealed);
	});

	it("ownership never grants non-ownership capabilities", () => {
		const access = authorizationFor(session("member"));
		expect(
			access.can("membership.reactivate", { ownerPrincipalId: SELF }),
		).toBe(false);
		expect(access.can("inventory.manage", { ownerPrincipalId: SELF })).toBe(
			false,
		);
	});

	it("billing-authority roles reactivate memberships; broader member admins do not", () => {
		expect(
			authorizationFor(session("treasurer")).can("membership.reactivate"),
		).toBe(true);
		expect(
			authorizationFor(session("coach")).can("membership.reactivate"),
		).toBe(false);
		expect(
			authorizationFor(session("quartermaster")).can("membership.reactivate"),
		).toBe(false);
	});

	it("settings capability is narrower than directory access", () => {
		const access = authorizationFor(session("coach"));
		expect(access.can("members.directory.read")).toBe(true);
		expect(access.can("members.settings.edit")).toBe(false);
	});

	it("require() is a thin adapter over decide()", () => {
		expect(() =>
			authorizationFor(session("quartermaster")).require("inventory.manage"),
		).not.toThrow();
		expect(() => authorizationFor(null).require("inventory.manage")).toThrow(
			expect.objectContaining({ status: 401 }),
		);
		expect(() =>
			authorizationFor(session("member")).require("inventory.manage"),
		).toThrow(expect.objectContaining({ status: 403 }));
		expect(() =>
			authorizationFor(session("member")).require("members.profile.read", {
				ownerPrincipalId: OTHER,
			}),
		).toThrow(expect.objectContaining({ status: 404 }));
	});
});

describe("authorizationFor — navigation", () => {
	const titles = (s: PhoenixSessionProjection | null) =>
		authorizationFor(s)
			.navigation()
			.navMain.map((group) => group.title);

	it("is empty for anonymous sessions", () => {
		expect(titles(null)).toEqual([]);
	});

	it("shows ordinary members only self-service sections", () => {
		expect(titles(session("member"))).toEqual([
			"My Workshops",
			"Equipment",
			"My Loans",
		]);
	});

	it("shows inventory operators the inventory group with every sub-item", () => {
		const nav = authorizationFor(session("quartermaster")).navigation();
		const inventory = nav.navMain.find((group) => group.title === "Inventory");
		expect(inventory?.items?.map((item) => item.title)).toEqual([
			"Loan queue",
			"Items",
			"Categories",
			"Containers",
		]);
		expect(titles(session("member"))).not.toContain("Inventory");
	});

	it("contains exactly the entries allowed by the same capability decisions", () => {
		for (const role of EVERY_ROLE) {
			const access = authorizationFor(session(role));
			const nav = access.navigation();
			const everything = authorizationFor(session(...EVERY_ROLE)).navigation();
			const expected = everything.navMain
				.map((group) => group.title)
				.filter((title) => {
					const capability = NAV_CAPABILITY.get(title);
					if (!capability) throw new Error(`untabled nav entry: ${title}`);
					return access.can(capability);
				});
			expect(nav.navMain.map((group) => group.title)).toEqual(expected);
		}
	});

	it("does not leak role sets or capabilities to the client", () => {
		const nav = authorizationFor(session(...EVERY_ROLE)).navigation();
		for (const group of nav.navMain) {
			expect(group).not.toHaveProperty("role");
			expect(group).not.toHaveProperty("requires");
			for (const item of group.items ?? []) {
				expect(item).not.toHaveProperty("role");
				expect(item).not.toHaveProperty("requires");
			}
		}
	});
});

/** Navigation title → governing capability (the observable contract). */
const NAV_CAPABILITY = new Map<string, Capability>(
	Object.entries({
		"Beginners Workshop": "beginners.workshop.read",
		Members: "members.directory.read",
		"Discord Doctor": "discord.doctor.use",
		Workshops: "workshops.manage",
		"My Workshops": "workshops.own.read",
		Inventory: "inventory.manage",
		Equipment: "inventory.catalog.read",
		"My Loans": "inventory.loans.own.read",
	} satisfies Record<string, Capability>),
);

/**
 * Protected route table: SvelteKit route id → governing capability and the
 * resource context derived from params. The hook and the route-local
 * `require()` must agree on every row.
 */
const PROTECTED_ROUTES: Array<{
	id: string;
	params?: Record<string, string>;
	requires: Capability;
	resource?: { ownerPrincipalId: string };
}> = [
	{ id: "/dashboard/beginners-workshop", requires: "beginners.workshop.read" },
	{ id: "/dashboard/members", requires: "members.directory.read" },
	{ id: "/dashboard/members/directory", requires: "members.directory.read" },
	{ id: "/dashboard/members/invitations", requires: "members.directory.read" },
	{
		id: "/dashboard/members/[memberId]",
		params: { memberId: OTHER },
		requires: "members.profile.read",
		resource: { ownerPrincipalId: OTHER },
	},
	{
		id: "/dashboard/members/[memberId]",
		params: { memberId: SELF },
		requires: "members.profile.read",
		resource: { ownerPrincipalId: SELF },
	},
	{ id: "/dashboard/discord-doctor", requires: "discord.doctor.use" },
	{ id: "/dashboard/workshops", requires: "workshops.manage" },
	{ id: "/dashboard/workshops/create", requires: "workshops.manage" },
	{ id: "/dashboard/workshops/[id]/attendees", requires: "workshops.manage" },
	{ id: "/dashboard/my-workshops", requires: "workshops.own.read" },
	{ id: "/dashboard/inventory", requires: "inventory.manage" },
	{ id: "/dashboard/inventory/items", requires: "inventory.manage" },
	{ id: "/dashboard/inventory/categories", requires: "inventory.manage" },
	{ id: "/dashboard/inventory/containers", requires: "inventory.manage" },
	{ id: "/dashboard/inventory/loans", requires: "inventory.manage" },
	{ id: "/dashboard/equipment", requires: "inventory.catalog.read" },
	{ id: "/dashboard/my-loans", requires: "inventory.loans.own.read" },
];

describe("guardRoute — request-hook gating", () => {
	it("agrees with route-local require() for every protected route and role", () => {
		for (const route of PROTECTED_ROUTES) {
			for (const role of EVERY_ROLE) {
				const s = session(role);
				const access = authorizationFor(s);
				const outcome = guardRoute(s, {
					id: route.id,
					params: route.params ?? {},
				});
				const allowed = access.can(route.requires, route.resource);
				expect(
					outcome.kind,
					`${role} on ${route.id} ${JSON.stringify(route.params ?? {})}`,
				).toBe(allowed ? "allow" : "redirect");
			}
		}
	});

	it("redirects denied users to their own profile", () => {
		expect(
			guardRoute(session("member"), {
				id: "/dashboard/inventory/items",
				params: {},
			}),
		).toEqual({ kind: "redirect", location: `/dashboard/members/${SELF}` });
	});

	it("redirects anonymous users on protected routes to /auth", () => {
		expect(
			guardRoute(null, { id: "/dashboard/inventory", params: {} }),
		).toEqual({ kind: "redirect", location: "/auth" });
	});

	it("lets members reach their own profile but not another member's", () => {
		const s = session("member");
		expect(
			guardRoute(s, {
				id: "/dashboard/members/[memberId]",
				params: { memberId: SELF },
			}),
		).toEqual({ kind: "allow" });
		expect(
			guardRoute(s, {
				id: "/dashboard/members/[memberId]",
				params: { memberId: OTHER },
			}).kind,
		).toBe("redirect");
	});

	it("matches routes by segment boundary, not substring", () => {
		const member = session("member");
		// `/dashboard/inventory-report` is not under `/dashboard/inventory`.
		expect(
			guardRoute(member, { id: "/dashboard/inventory-report", params: {} }),
		).toEqual({ kind: "allow" });
		// `/dashboard/members` must not be governed by a rule for
		// `/dashboard/members/[memberId]` (or vice versa).
		expect(
			guardRoute(member, { id: "/dashboard/members", params: {} }).kind,
		).toBe("redirect");
	});

	it("leaves public and otherwise ungated routes ungated", () => {
		for (const id of [
			"/dashboard",
			"/auth",
			"/(public)/waitlist",
			"/(public)/workshops/[id]",
			null,
		]) {
			expect(guardRoute(null, { id, params: {} })).toEqual({ kind: "allow" });
			expect(guardRoute(session("member"), { id, params: {} })).toEqual({
				kind: "allow",
			});
		}
	});
});
