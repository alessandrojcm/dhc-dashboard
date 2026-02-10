import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { createContainerService } from "$lib/server/services/inventory";

export const load = async ({
	locals,
	platform,
}: {
	locals: App.Locals;
	platform: App.Platform;
}) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const containerService = createContainerService(platform!, session);

	// Load existing containers for parent selection
	const containers = await containerService.findMany();

	return {
		containers: containers || [],
	};
};
