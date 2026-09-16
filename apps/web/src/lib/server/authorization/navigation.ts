/**
 * GH-510: dashboard navigation definition.
 *
 * Navigation is a *consumer* of authorization policy, never its source: every
 * entry names the capability that governs it, and `navigationFor` filters the
 * tree with the same `decide` the guards use, so what the sidebar shows and
 * what routes accept cannot drift.
 */
import type { NavData, NavigationGroup, NavigationItem } from "$lib/types";
import type { Capability } from "./capabilities";

type NavigationItemDefinition = NavigationItem & { requires: Capability };
type NavigationGroupDefinition = Omit<NavigationGroup, "items"> & {
	requires: Capability;
	items?: NavigationItemDefinition[];
};
type NavigationDefinition = NavigationGroupDefinition[];

const navigation: NavigationDefinition = [
	{
		title: "Beginners Workshop",
		url: "/dashboard/beginners-workshop",
		requires: "beginners.workshop.read",
	},
	{
		title: "Members",
		url: "/dashboard/members",
		requires: "members.directory.read",
	},
	{
		title: "Discord Doctor",
		url: "/dashboard/discord-doctor",
		requires: "discord.doctor.use",
	},
	{
		title: "Workshops",
		url: "/dashboard/workshops",
		requires: "workshops.manage",
	},
	{
		title: "My Workshops",
		url: "/dashboard/my-workshops",
		requires: "workshops.own.read",
	},
	{
		title: "Inventory",
		url: "/dashboard/inventory",
		requires: "inventory.manage",
		items: [
			{
				title: "Loan queue",
				url: "/dashboard/inventory/loans",
				requires: "inventory.manage",
			},
			{
				title: "Items",
				url: "/dashboard/inventory/items",
				requires: "inventory.manage",
			},
			{
				title: "Categories",
				url: "/dashboard/inventory/categories",
				requires: "inventory.manage",
			},
			{
				title: "Containers",
				url: "/dashboard/inventory/containers",
				requires: "inventory.manage",
			},
		],
	},
	{
		// Member catalog browse (ALE-288)
		title: "Equipment",
		url: "/dashboard/equipment",
		requires: "inventory.catalog.read",
	},
	{
		// Own-loan history (ALE-288)
		title: "My Loans",
		url: "/dashboard/my-loans",
		requires: "inventory.loans.own.read",
	},
];

/**
 * Derives the visible navigation from a capability predicate. Capabilities
 * are stripped from the result so the client receives presentation data only.
 */
export function navigationFor(
	can: (capability: Capability) => boolean,
): NavData {
	const navMain = navigation.flatMap<NavigationGroup>((group) => {
		if (!can(group.requires)) return [];
		const { requires: _requires, items, ...visible } = group;
		if (!items) return [visible];

		const visibleItems = items.flatMap<NavigationItem>((item) => {
			if (!can(item.requires)) return [];
			const { requires: _itemRequires, ...visibleItem } = item;
			return [visibleItem];
		});
		if (visibleItems.length === 0) return [];
		return [{ ...visible, items: visibleItems }];
	});

	return { navMain };
}
