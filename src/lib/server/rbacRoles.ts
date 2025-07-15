import type { NavData, NavigationGroup } from '$lib/types';

const data: NavData = {
	navMain: [
		{
			title: 'Beginners Workshop',
			url: 'beginners-workshop',
			role: new Set(['admin', 'coach', 'beginners_coordinator', 'president'])
		},
		{
			title: 'Members',
			url: 'members',
			role: new Set([
				'admin',
				'president',
				'treasurer',
				'committee_coordinator',
				'sparring_coordinator',
				'workshop_coordinator',
				'beginners_coordinator',
				'quartermaster',
				'pr_manager',
				'volunteer_coordinator',
				'research_coordinator',
				'coach'
			])
		},
		{
			title: 'Workshops',
			url: 'workshops',
			role: new Set(['admin', 'president', 'committee_coordinator'])
		},
		{
			title: 'My Workshops',
			url: 'my-workshops',
			role: new Set(['member']) // All authenticated users have member role
		}
	]
};

function filterNavByRoles(nav: NavData, roles: string[]): NavData {
	return {
		navMain: nav.navMain.reduce<NavigationGroup[]>((filtered, group) => {
			// Check if user has any role required for the group
			const hasGroupRole = Array.from(group.role).some((role) => roles.includes(role));

			if (!hasGroupRole) {
				return filtered;
			}

			// If group has items, filter them by role too
			if (group.items) {
				const filteredItems = group.items.filter((item) =>
					Array.from(item.role).some((role) => roles.includes(role))
				);

				if (filteredItems.length > 0) {
					filtered.push({ ...group, items: filteredItems });
				} else if (!group.items) {
					// If group has no items and user has access, include the group
					filtered.push(group);
				}
			} else {
				// Group has no items and user has access, include it
				filtered.push(group);
			}

			return filtered;
		}, [])
	};
}

export { data as navData, filterNavByRoles };
