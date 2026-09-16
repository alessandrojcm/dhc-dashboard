/**
 * GH-510: protected-route rules for the request hook.
 *
 * Rules are matched against the SvelteKit *route id* (`event.route.id`, e.g.
 * `/dashboard/members/[memberId]`), never the raw URL, and only at segment
 * boundaries — `/dashboard/inventory-report` is not under
 * `/dashboard/inventory`. The first matching rule governs the request, which
 * is how the contextual `[memberId]` rule takes precedence over the broader
 * `/dashboard/members` prefix.
 *
 * Routes not listed here are ungated at the hook level (they still need a
 * session under `/dashboard`, enforced by the auth guard). Route loads keep
 * calling `require()` where they need a resource check or a specific status.
 */
import type { Capability, ResourceContext } from "./capabilities";

export type RouteParams = Partial<Record<string, string>>;

type RouteMatcher = (routeId: string) => boolean;

/** Matches the route id itself and every route nested under it. */
export function routePrefix(prefix: string): RouteMatcher {
	return (routeId) => routeId === prefix || routeId.startsWith(`${prefix}/`);
}

/** How the hook reacts when the governing capability is denied. */
export type DenyBehaviour = "redirect-to-own-profile";

export type ProtectedRoute = {
	match: RouteMatcher;
	requires: Capability;
	/** Derives explicit resource context from the matched route's params. */
	resource?: (params: RouteParams) => ResourceContext;
	onDeny: DenyBehaviour;
};

type ProtectedRouteDefinition = ProtectedRoute[];

const protectedRoutes: ProtectedRouteDefinition = [
	{
		match: routePrefix("/dashboard/beginners-workshop"),
		requires: "beginners.workshop.read",
		onDeny: "redirect-to-own-profile",
	},
	{
		// Contextual: a member may open their own profile (and anything nested
		// under it). Listed before the directory prefix so it governs the
		// `[memberId]` subtree.
		match: routePrefix("/dashboard/members/[memberId]"),
		requires: "members.profile.read",
		resource: (params) => ({ ownerPrincipalId: params.memberId }),
		onDeny: "redirect-to-own-profile",
	},
	{
		match: routePrefix("/dashboard/members"),
		requires: "members.directory.read",
		onDeny: "redirect-to-own-profile",
	},
	{
		match: routePrefix("/dashboard/discord-doctor"),
		requires: "discord.doctor.use",
		onDeny: "redirect-to-own-profile",
	},
	{
		match: routePrefix("/dashboard/workshops"),
		requires: "workshops.manage",
		onDeny: "redirect-to-own-profile",
	},
	{
		match: routePrefix("/dashboard/my-workshops"),
		requires: "workshops.own.read",
		onDeny: "redirect-to-own-profile",
	},
	{
		match: routePrefix("/dashboard/inventory"),
		requires: "inventory.manage",
		onDeny: "redirect-to-own-profile",
	},
	{
		match: routePrefix("/dashboard/equipment"),
		requires: "inventory.catalog.read",
		onDeny: "redirect-to-own-profile",
	},
	{
		match: routePrefix("/dashboard/my-loans"),
		requires: "inventory.loans.own.read",
		onDeny: "redirect-to-own-profile",
	},
];

/** The first rule governing `routeId`, or `undefined` when it is ungated. */
export function governingRule(
	routeId: string | null,
): ProtectedRoute | undefined {
	if (routeId === null) return undefined;
	return protectedRoutes.find((rule) => rule.match(routeId));
}
