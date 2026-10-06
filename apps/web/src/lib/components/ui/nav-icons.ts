import type { ResolvedPathname } from "$app/types";
import {
	Boxes,
	CalendarDays,
	ClipboardList,
	GraduationCap,
	Handshake,
	House,
	Megaphone,
	Package,
	Shield,
	Stethoscope,
	Swords,
	Tags,
	UsersRound,
	type LucideIcon,
} from "@lucide/svelte";

export type NavIcon = LucideIcon;

/**
 * Sidebar icon per navigation URL. Keyed by URL rather than title because
 * titles are copy and get reworded; a URL is the entry's identity.
 *
 * Every entry in `#lib/server/authorization/navigation.js` must have an icon —
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
	"/dashboard/training-announcements": Megaphone,
	"/dashboard/equipment": Shield,
	"/dashboard/my-loans": Handshake,
	"/dashboard/inventory": Boxes,
	"/dashboard/inventory/loans": ClipboardList,
	"/dashboard/inventory/items": Package,
	"/dashboard/inventory/categories": Tags,
	"/dashboard/inventory/containers": Boxes,
} satisfies Partial<Record<ResolvedPathname, NavIcon>>;

export function navIconFor(url: ResolvedPathname): NavIcon {
	if (!(url in navIcons)) {
		throw new Error(`No sidebar icon for navigation entry ${url}`);
	}
	// SAFETY: the `in` check above proves `url` is one of `navIcons`' keys;
	// TypeScript does not narrow a `ResolvedPathname` through `in` on a const object.
	return navIcons[url as keyof typeof navIcons];
}
