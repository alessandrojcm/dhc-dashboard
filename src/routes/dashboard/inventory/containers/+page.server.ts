import type { PageServerLoadEvent } from "./$types";

export const load = async ({ parent }: PageServerLoadEvent) => {
	const { canEdit } = await parent();

	// Data fetching happens client-side with TanStack Query
	return {
		canEdit,
	};
};
