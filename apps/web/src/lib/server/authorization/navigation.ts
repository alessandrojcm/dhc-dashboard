/**
 * GH-510: dashboard navigation definition.
 *
 * Navigation is a *consumer* of authorization policy, never its source: every
 * entry names the capability that governs it, and `navigationFor` filters the
 * tree with the same `decide` the guards use, so what the sidebar shows and
 * what routes accept cannot drift.
 */
import { resolve } from "$app/paths";
import type { NavData, NavigationGroup, NavigationItem } from "#lib/types.js";
import type { Capability } from "./capabilities";

type NavigationItemDefinition = NavigationItem & { requires: Capability };
type NavigationGroupDefinition = Omit<NavigationGroup, "items"> & {
	requires: Capability;
	items?: NavigationItemDefinition[];
};
type NavigationDefinition = NavigationGroupDefinition[];

export const navigation: NavigationDefinition = [
	{
		title: "Beginners Workshop",
		url: resolve("dashboard/beginners-workshop"),
		requires: "beginners.waitlist.manage",
	},
	{
		title: "Members",
		url: resolve("dashboard/members"),
		requires: "members.directory.read",
	},
	{
		title: "Discord Doctor",
		url: resolve("dashboard/discord-doctor"),
		requires: "discord.doctor.use",
	},
	{
		// ALE-330: committee-managed Discord posts about training. Sits with
		// the other club-communication entry rather than inside a group.
		title: "Training Announcements",
		url: resolve("dashboard/training-announcements"),
		requires: "training_announcements.manage",
	},
	{
		// ADR 0028: committee email to the membership, beside the other
		// club-communication entry.
		title: "Member Emails",
		url: resolve("dashboard/member-emails"),
		requires: "member_announcements.send",
	},
	{
		title: "Workshops",
		url: resolve("dashboard/workshops"),
		requires: "workshops.manage",
	},
	{
		title: "My Workshops",
		url: resolve("dashboard/my-workshops"),
		requires: "workshops.own.read",
	},
	{
		// Member catalog browse (ALE-288). Member self-service entries sit
		// together; the operator-only Inventory group closes the list.
		title: "Equipment",
		url: resolve("dashboard/equipment"),
		requires: "inventory.catalog.read",
	},
	{
		// Own-loan history (ALE-288)
		title: "My Loans",
		url: resolve("dashboard/my-loans"),
		requires: "inventory.loans.own.read",
	},
	{
		title: "Inventory",
		url: resolve("dashboard/inventory"),
		requires: "inventory.manage",
		items: [
			{
				title: "Loan queue",
				url: resolve("dashboard/inventory/loans"),
				requires: "inventory.manage",
			},
			{
				title: "Items",
				url: resolve("dashboard/inventory/items"),
				requires: "inventory.manage",
			},
			{
				title: "Categories",
				url: resolve("dashboard/inventory/categories"),
				requires: "inventory.manage",
			},
			{
				title: "Containers",
				url: resolve("dashboard/inventory/containers"),
				requires: "inventory.manage",
			},
		],
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
