import { describe, expect, it } from "vitest";
import { isHttpError, isRedirect } from "@sveltejs/kit";
import { getClient } from "@dhc/api-client";
import {
	authorizationFor,
	CAPABILITIES,
	guardRoute,
	type Capability,
	type PhoenixSessionProjection,
} from "#lib/server/authorization/index.js";
import { navigation } from "./navigation";
import { governingRule, protectedRoutes } from "./routes";

/**
 * GH-510: behavioural tests for the frontend authorization boundary.
 *
 * Everything is observed through `authorizationFor(session)` and
 * `guardRoute(session, route)`; navigation definitions and protected-route
 * rules are private implementation details.
 *
 * ALE-344: Phoenix works out a session's capabilities (`Dhc.Auth.Capabilities`,
 * whose role table `capabilities_test.exs` pins). The dashboard never sees a
 * role, so these sessions are built from capability lists directly.
 */

const SELF = "11111111-1111-1111-1111-111111111111";
const OTHER = "22222222-2222-2222-2222-222222222222";

/** A session as Phoenix projects it, holding exactly these capabilities. */
function session(...capabilities: Capability[]): PhoenixSessionProjection {
	return {
		principal: { id: SELF, email: "u@example.com" },
		roles: [],
		capabilities,
	};
}

/** What Phoenix grants a plain member. */
const MEMBER: Capability[] = [
	"beginners.workshops.assigned.read",
	"inventory.catalog.read",
	"inventory.loans.own.read",
	"workshops.own.read",
];

/** The resource owner also holds these (and is concealed from otherwise). */
const OWNER_SCOPED: Capability[] = [
	"members.profile.read",
	"members.profile.update",
];

/** A resource's assigned principals also hold these (ALE-379). */
const ASSIGNMENT_SCOPED: Capability[] = ["beginners.workshops.run"];

/** Capability sets the exhaustive loops visit: none, each alone, member, all. */
const SESSIONS: Capability[][] = [
	[],
	...CAPABILITIES.map((capability) => [capability]),
	MEMBER,
	[...CAPABILITIES],
];

const label = (capabilities: Capability[]) =>
	capabilities.length === 0 ? "(none)" : capabilities.join("+");

describe("authorizationFor — capability registry", () => {
	describe.each(CAPABILITIES)("%s", (capability) => {
		it("is granted by holding it", () => {
			expect(authorizationFor(session(capability)).decide(capability)).toEqual({
				allowed: true,
			});
		});

		it("is denied by holding every other capability", () => {
			const others = CAPABILITIES.filter((other) => other !== capability);
			const denial =
				OWNER_SCOPED.includes(capability) ||
				ASSIGNMENT_SCOPED.includes(capability)
					? { allowed: false, status: 404, reason: "concealed_resource" }
					: { allowed: false, status: 403, reason: "missing_capability" };
			expect(authorizationFor(session(...others)).decide(capability)).toEqual(
				denial,
			);
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
	it("decides from the session's capabilities, never its roles", () => {
		const roleOnly = {
			principal: { id: SELF, email: "u@example.com" },
			roles: ["admin"],
			capabilities: [],
		} satisfies PhoenixSessionProjection;
		expect(authorizationFor(roleOnly).decide("inventory.manage")).toEqual({
			allowed: false,
			status: 403,
			reason: "missing_capability",
		});

		const capabilityOnly = {
			...roleOnly,
			roles: [],
			capabilities: ["inventory.manage" as const],
		} satisfies PhoenixSessionProjection;
		expect(authorizationFor(capabilityOnly).can("inventory.manage")).toBe(true);
	});

	it("inventory operators can manage inventory, ordinary members cannot", () => {
		expect(
			authorizationFor(session("inventory.manage")).can("inventory.manage"),
		).toBe(true);
		expect(
			authorizationFor(session(...MEMBER)).decide("inventory.manage"),
		).toEqual({ allowed: false, status: 403, reason: "missing_capability" });
	});

	it("holders of the profile capabilities can read and update another member's profile", () => {
		const access = authorizationFor(
			session("members.profile.read", "members.profile.update"),
		);
		const other = { ownerPrincipalId: OTHER };
		expect(access.can("members.profile.read", other)).toBe(true);
		expect(access.can("members.profile.update", other)).toBe(true);
	});

	it("members can read/update their own profile without the capability", () => {
		const access = authorizationFor(session(...MEMBER));
		const own = { ownerPrincipalId: SELF };
		expect(access.decide("members.profile.read", own)).toEqual({
			allowed: true,
		});
		expect(access.can("members.profile.update", own)).toBe(true);
	});

	it("ordinary members receive a concealed denial for another member's profile", () => {
		const access = authorizationFor(session(...MEMBER));
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
		const access = authorizationFor(session(...MEMBER));
		expect(
			access.can("membership.reactivate", { ownerPrincipalId: SELF }),
		).toBe(false);
		expect(access.can("inventory.manage", { ownerPrincipalId: SELF })).toBe(
			false,
		);
	});

	it("assigned principals run their workshop; anyone else is concealed (ALE-379)", () => {
		const access = authorizationFor(session(...MEMBER));
		const concealed = {
			allowed: false,
			status: 404,
			reason: "concealed_resource",
		};
		expect(
			access.decide("beginners.workshops.run", {
				assignedPrincipalIds: [OTHER, SELF],
			}),
		).toEqual({ allowed: true });
		expect(
			access.decide("beginners.workshops.run", {
				assignedPrincipalIds: [OTHER],
			}),
		).toEqual(concealed);
		expect(access.decide("beginners.workshops.run")).toEqual(concealed);
		// Ownership is not an assignment, nor the reverse.
		expect(
			access.can("beginners.workshops.run", { ownerPrincipalId: SELF }),
		).toBe(false);
		expect(
			access.can("members.profile.read", { assignedPrincipalIds: [SELF] }),
		).toBe(false);
		// The managers hold it by role, assigned or not.
		expect(
			authorizationFor(session("beginners.workshops.run")).can(
				"beginners.workshops.run",
				{ assignedPrincipalIds: [] },
			),
		).toBe(true);
	});

	it("membership reactivation needs its own capability, not directory access", () => {
		expect(
			authorizationFor(session("membership.reactivate")).can(
				"membership.reactivate",
			),
		).toBe(true);
		expect(
			authorizationFor(
				session("members.directory.read", "members.profile.update"),
			).can("membership.reactivate"),
		).toBe(false);
	});

	it("settings capability is narrower than directory access", () => {
		const access = authorizationFor(session("members.directory.read"));
		expect(access.can("members.directory.read")).toBe(true);
		expect(access.can("members.settings.edit")).toBe(false);
	});

	it("require() is a thin adapter over decide()", () => {
		expect(() =>
			authorizationFor(session("inventory.manage")).require("inventory.manage"),
		).not.toThrow();
		expect(() => authorizationFor(null).require("inventory.manage")).toThrow(
			expect.objectContaining({ status: 401 }),
		);
		expect(() =>
			authorizationFor(session(...MEMBER)).require("inventory.manage"),
		).toThrow(expect.objectContaining({ status: 403 }));
		expect(() =>
			authorizationFor(session(...MEMBER)).require("members.profile.read", {
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
		expect(titles(session(...MEMBER))).toEqual([
			"My Workshops",
			"Equipment",
			"My Loans",
		]);
	});

	it("shows My Beginners' Workshops only while the member has an assignment (ALE-379)", () => {
		const access = authorizationFor(session(...MEMBER));
		const titlesWith = (hasBeginnersWorkshopAssignments: boolean) =>
			access
				.navigation({ hasBeginnersWorkshopAssignments })
				.navMain.map((group) => group.title);
		expect(titlesWith(false)).not.toContain("My Beginners' Workshops");
		expect(titlesWith(true)).toContain("My Beginners' Workshops");
		// The fact never reveals an entry the capability denies.
		expect(
			authorizationFor(session())
				.navigation({ hasBeginnersWorkshopAssignments: true })
				.navMain.map((group) => group.title),
		).toEqual([]);
	});

	it("shows inventory operators the inventory group with every sub-item", () => {
		const nav = authorizationFor(session("inventory.manage")).navigation();
		const inventory = nav.navMain.find((group) => group.title === "Inventory");
		expect(inventory?.items?.map((item) => item.title)).toEqual([
			"Loan queue",
			"Items",
			"Categories",
			"Containers",
		]);
		expect(titles(session(...MEMBER))).not.toContain("Inventory");
	});

	it("contains exactly the entries allowed by the same capability decisions", () => {
		const everything = authorizationFor(session(...CAPABILITIES)).navigation();
		for (const capabilities of SESSIONS) {
			const access = authorizationFor(session(...capabilities));
			const nav = access.navigation();
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
		const nav = authorizationFor(session(...CAPABILITIES)).navigation();
		for (const group of nav.navMain) {
			expect(group).not.toHaveProperty("role");
			expect(group).not.toHaveProperty("requires");
			expect(group).not.toHaveProperty("shownWhen");
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
					for (const capabilities of SESSIONS) {
						const s = session(...capabilities);
						const outcome = guardRoute(s, { id: routeId, params });
						const description = `${label(capabilities)} load on ${routeId} ${JSON.stringify(params)}`;
						if (outcome.kind === "allow") {
							await expectLoadAllows(load, loadEvent(s, params), description);
						} else {
							await expectLoadDenies(load, loadEvent(s, params), description);
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
			guardRoute(session(...MEMBER), {
				id: "/dashboard/inventory/items",
				params: {},
			}),
		).toEqual({ kind: "redirect", location: `/dashboard/members/${SELF}` });
	});

	it("keeps Training Announcements committee-only (ALE-330)", () => {
		const member = session(...MEMBER);
		expect(authorizationFor(member).can("training_announcements.manage")).toBe(
			false,
		);
		const titlesFor = (capabilities: Capability[]) =>
			authorizationFor(session(...capabilities))
				.navigation()
				.navMain.map((group) => group.title);
		expect(titlesFor(MEMBER)).not.toContain("Training Announcements");
		expect(titlesFor(["training_announcements.manage"])).toContain(
			"Training Announcements",
		);
		expect(
			guardRoute(member, {
				id: "/dashboard/training-announcements",
				params: {},
			}),
		).toEqual({ kind: "redirect", location: `/dashboard/members/${SELF}` });
	});

	it("redirects anonymous users on protected routes to /auth", () => {
		expect(
			guardRoute(null, { id: "/dashboard/inventory", params: {} }),
		).toEqual({ kind: "redirect", location: "/auth" });
	});

	it("lets every member reach the door route; Phoenix conceals the workshop (ALE-379)", () => {
		const door = {
			id: "/dashboard/beginners-workshop/workshops/[workshopId]/door",
			params: { workshopId: OTHER },
		};
		expect(guardRoute(session(...MEMBER), door)).toEqual({ kind: "allow" });
		expect(guardRoute(session(), door).kind).toBe("redirect");
		// The rest of the section stays the Waitlist managers'.
		expect(
			guardRoute(session(...MEMBER), {
				id: "/dashboard/beginners-workshop",
				params: {},
			}).kind,
		).toBe("redirect");
	});

	it("lets members reach their own profile but not another member's", () => {
		const s = session(...MEMBER);
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
		const member = session(...MEMBER);
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
			expect(guardRoute(session(...MEMBER), { id, params: {} })).toEqual({
				kind: "allow",
			});
		}
	});
});
