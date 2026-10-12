export const BEGINNERS_WORKSHOP_SECTIONS = [
	{
		id: "dashboard",
		label: "Dashboard",
		href: "/dashboard/beginners-workshop",
	},
	{
		id: "waitlist",
		label: "Waitlist",
		href: "/dashboard/beginners-workshop/waitlist",
	},
	{
		id: "workshops",
		label: "Workshops",
		href: "/dashboard/beginners-workshop/workshops",
	},
	{
		id: "email-templates",
		label: "Email templates",
		href: "/dashboard/beginners-workshop/email-templates",
	},
	{
		id: "invitable",
		label: "Invite members",
		href: "/dashboard/beginners-workshop/invitable",
	},
] as const;

export function isBeginnersWorkshopSection(routeId: string | null): boolean {
	return BEGINNERS_WORKSHOP_SECTIONS.some(
		(section) => section.href === routeId,
	);
}
