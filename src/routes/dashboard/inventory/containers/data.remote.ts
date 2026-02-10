import { form, getRequestEvent } from "$app/server";
import { redirect } from "@sveltejs/kit";
import * as v from "valibot";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	createContainerService,
	ContainerCreateSchema,
	ContainerUpdateSchema,
} from "$lib/server/services/inventory";

export const createContainer = form(ContainerCreateSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const containerService = createContainerService(event.platform!, session);

	const container = await containerService.create(data);

	redirect(303, `/dashboard/inventory/containers/${container.id}`);
});

export const updateContainer = form(ContainerUpdateSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const containerId = event.params.id!;
	const containerService = createContainerService(event.platform!, session);

	await containerService.update(containerId, data);

	redirect(303, `/dashboard/inventory/containers/${containerId}`);
});

export const deleteContainer = form(v.object({}), async () => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const containerId = event.params.id!;
	const containerService = createContainerService(event.platform!, session);

	const containerWithCount =
		await containerService.getWithItemCount(containerId);

	if (containerWithCount.itemCount > 0) {
		throw new Error("Cannot delete a container that contains items.");
	}

	await containerService.delete(containerId);

	redirect(303, "/dashboard/inventory/containers");
});
