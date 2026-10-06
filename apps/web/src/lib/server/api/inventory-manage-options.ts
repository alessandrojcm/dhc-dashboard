import { getRequestEvent } from "$app/server";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorize } from "#lib/server/auth.js";

/**
 * Generated-client options for a quartermaster inventory command, after
 * checking the `inventory.manage` capability. Shared by the inventory
 * quartermaster `.remote.ts` files; `inventoryCommand` stays request-free.
 */
export async function inventoryManageOptions() {
	const event = getRequestEvent();
	await authorize(event.locals, "inventory.manage");
	return apiClientOptions(event.cookies);
}

export type InventoryManageOptions = Awaited<
	ReturnType<typeof inventoryManageOptions>
>;
