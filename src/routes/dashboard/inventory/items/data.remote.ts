import { form, getRequestEvent } from "$app/server";
import { redirect } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	createItemService,
	ItemCreateSchema,
	ItemUpdateSchema,
} from "$lib/server/services/inventory";

export const createItem = form(ItemCreateSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const itemService = createItemService(event.platform!, session);

	const item = await itemService.create(data);

	redirect(303, `/dashboard/inventory/items/${item.id}`);
});

export const updateItem = form(ItemUpdateSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const itemId = event.params.id!;
	const itemService = createItemService(event.platform!, session);

	await itemService.update(itemId, data);

	return { success: "Item updated successfully" };
});
