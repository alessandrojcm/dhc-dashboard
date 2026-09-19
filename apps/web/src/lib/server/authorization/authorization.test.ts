import { describe, expect, it } from "vitest";
import { isHttpError, isRedirect } from "@sveltejs/kit";
import { getClient } from "@dhc/api-client";
import {
	authorizationFor,
	CAPABILITIES,
	guardRoute,
	type Capability,
	type PhoenixSessionProjection,
} from "$lib/server/authorization";
import { navigation } from "./navigation";
import { governingRule, protectedRoutes } from "./routes";

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

/** Navigation title → governing capability, taken from the real definition. */
const NAV_CAPABILITY = new Map<string, Capability>(
	navigation.map((group) => [group.title, group.requires]),
);

type PageLoadParams = { memberId?: string };

type PageLoadEvent = {
	locals: {
		session: PhoenixSessionProjection | null;
		safeGetSession: () => Promise<{
			session: PhoenixSessionProjection | null;
		}>;
	};
	params: PageLoadParams;
	url: URL;
	cookies: { get: (name: string) => string | undefined };
	depends: (dep: string) => void;
};

type PageServerModule = {
	load?: (event: PageLoadEvent) => void | Promise<void>;
};

const pageServers = import.meta.glob<PageServerModule>(
	"../../../routes/dashboard/**/+page.server.ts",
	{ eager: true },
);
const layoutServers = import.meta.glob<PageServerModule>(
	"../../../routes/dashboard/**/+layout.server.ts",
	{ eager: true },
);

function routeIdFromGlob(path: string, kind: "page" | "layout"): string {
	const marker = "/routes";
	const index = path.lastIndexOf(marker);
	const suffix = kind === "page" ? "/+page.server.ts" : "/+layout.server.ts";
	return path.slice(index + marker.length).replace(suffix, "");
}

function modulesByRouteId(
	modules: Record<string, PageServerModule>,
	kind: "page" | "layout",
): Map<string, PageServerModule> {
	return new Map(
		Object.entries(modules).map(([path, mod]) => [
			routeIdFromGlob(path, kind),
			mod,
		]),
	);
}

const pages = modulesByRouteId(pageServers, "page");
const layouts = modulesByRouteId(layoutServers, "layout");

function pageLoadAt(
	prefix: string,
):
	| { routeId: string; load: NonNullable<PageServerModule["load"]> }
	| undefined {
	const exact = pages.get(prefix);
	if (exact?.load) return { routeId: prefix, load: exact.load };
	for (const [routeId, mod] of pages) {
		if (mod.load && routeId.startsWith(`${prefix}/[[`)) {
			return { routeId, load: mod.load };
		}
	}
	return undefined;
}

/**
 * The page `load` for a protected-route prefix, or the layout `load` that
 * sits on that prefix (inventory). Does not walk up to `/dashboard` — that
 * layout only checks for a session and would hide a missing capability load.
 */
function governingLoad(
	prefix: string,
):
	| { routeId: string; load: NonNullable<PageServerModule["load"]> }
	| undefined {
	const page = pageLoadAt(prefix);
	if (page) return page;
	const layout = layouts.get(prefix);
	if (layout?.load) return { routeId: prefix, load: layout.load };
	return undefined;
}

function paramSetsFor(routeId: string): PageLoadParams[] {
	if (!routeId.includes("[memberId]")) return [{}];
	return [{ memberId: SELF }, { memberId: OTHER }];
}

function loadEvent(
	session: PhoenixSessionProjection | null,
	params: PageLoadParams,
): PageLoadEvent {
	return {
		locals: {
			session,
			safeGetSession: async () => ({ session }),
		},
		params,
		url: new URL("http://localhost/dashboard"),
		cookies: { get: () => undefined },
		depends: () => {},
	};
}

function isCapabilityDenial(cause: unknown): boolean {
	if (isRedirect(cause)) return true;
	if (!isHttpError(cause)) return false;
	if (cause.status === 401 || cause.status === 403) return true;
	// require() conceals missing profile access as 404 "Not found".
	// The member-detail load maps a stubbed TypeError to 404 "Member not
	// found" after require() has already passed — that is not a denial.
	return cause.status === 404 && cause.body.message === "Not found";
}

async function expectLoadDenies(
	load: NonNullable<PageServerModule["load"]>,
	event: PageLoadEvent,
	label: string,
) {
	let denied = false;
	try {
		await load(event);
	} catch (cause) {
		expect(isCapabilityDenial(cause), label).toBe(true);
		denied = true;
	}
	expect(denied, label).toBe(true);
}

async function expectLoadAllows(
	load: NonNullable<PageServerModule["load"]>,
	event: PageLoadEvent,
	label: string,
) {
	try {
		await load(event);
	} catch (cause) {
		// Stubbed ky throws TypeError. A concealed_resource 404 must fail.
		expect(isCapabilityDenial(cause), label).toBe(false);
	}
}

describe("guardRoute — request-hook gating", () => {
	it("nav entries and protected-route rules name the same capability", () => {
		const entries = navigation.flatMap((group) => [
			{ title: group.title, url: group.url, requires: group.requires },
			...(group.items ?? []).map((item) => ({
				title: item.title,
				url: item.url,
				requires: item.requires,
			})),
		]);
		for (const entry of entries) {
			const rule = governingRule(entry.url);
			expect(rule, `no protected-route rule for ${entry.title}`).toBeDefined();
			expect(rule?.requires, entry.title).toBe(entry.requires);
		}
	});

	it("each protected-route rule has a governing load that agrees with the hook", async () => {
		const client = getClient();
		const previous = client.getConfig();
		client.setConfig({
			retry: 0,
			kyOptions: {
				timeout: 1,
				fetch: async () => {
					throw new TypeError("Failed to fetch");
				},
			},
		});
		try {
			for (const rule of protectedRoutes) {
				const governing = governingLoad(rule.prefix);
				expect(
					governing,
					`no page or layout load for ${rule.prefix}`,
				).toBeDefined();
				if (!governing) continue;

				const { routeId, load } = governing;
				for (const params of paramSetsFor(rule.prefix)) {
					for (const role of EVERY_ROLE) {
						const s = session(role);
						const outcome = guardRoute(s, { id: routeId, params });
						const label = `${role} load on ${routeId} ${JSON.stringify(params)}`;
						if (outcome.kind === "allow") {
							await expectLoadAllows(load, loadEvent(s, params), label);
						} else {
							await expectLoadDenies(load, loadEvent(s, params), label);
						}
					}
					await expectLoadDenies(
						load,
						loadEvent(null, params),
						`anonymous load on ${routeId}`,
					);
				}
			}
		} finally {
			client.setConfig(previous);
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
