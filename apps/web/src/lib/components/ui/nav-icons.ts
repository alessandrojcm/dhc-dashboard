import type { Component } from "svelte";
import type { Pathname } from "$app/types";
import {
	Boxes,
	CalendarDays,
	ClipboardList,
	GraduationCap,
	Handshake,
	House,
	Package,
	Shield,
	Stethoscope,
	Swords,
	Tags,
	UsersRound,
	type IconProps,
} from "@lucide/svelte";

export type NavIcon = Component<IconProps>;

/**
 * Sidebar icon per navigation URL. Keyed by URL rather than title because
 * titles are copy and get reworded; a URL is the entry's identity.
 *
 * Every entry in `$lib/server/authorization/navigation` must have an icon —
 * `nav-icons.test.ts` enforces it. There is deliberately no fallback: an
 * unknown entry used to render a chevron, which reads as "expandable" on a
 * plain link.
 */
export const navIcons = {
	"/dashboard": House,
	"/dashboard/beginners-workshop": GraduationCap,
	"/dashboard/members": UsersRound,
	"/dashboard/discord-doctor": Stethoscope,
	"/dashboard/workshops": CalendarDays,
	"/dashboard/my-workshops": Swords,
	"/dashboard/equipment": Shield,
	"/dashboard/my-loans": Handshake,
	"/dashboard/inventory": Boxes,
	"/dashboard/inventory/loans": ClipboardList,
	"/dashboard/inventory/items": Swords,
	"/dashboard/inventory/categories": Tags,
	"/dashboard/inventory/containers": Boxes,
} satisfies Partial<Record<Pathname, NavIcon>>;

export function navIconFor(url: Pathname): NavIcon {
	if (!(url in navIcons)) {
		throw new Error(`No sidebar icon for navigation entry ${url}`);
	}
	// SAFETY: the `in` check above proves `url` is one of `navIcons`' keys;
	// TypeScript does not narrow a `Pathname` through `in` on a const object.
	return navIcons[url as keyof typeof navIcons];
}
